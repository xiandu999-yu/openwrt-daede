#!/usr/bin/env bash

set -euo pipefail

fail() {
    printf 'promote-candidate: %s\n' "$*" >&2
    exit 1
}

for name in BASE_SHA CANDIDATE_SHA BUILD_RUN_ID STAGING R2_ACCESS_KEY_ID \
    R2_SECRET_ACCESS_KEY R2_ENDPOINT R2_BUCKET AGGREGATE_FEED_TOKEN GH_TOKEN; do
    [[ -n "${!name:-}" ]] || fail "missing $name"
done
[[ "$BASE_SHA" =~ ^[0-9a-f]{40}$ ]] || fail "invalid base SHA"
[[ "$CANDIDATE_SHA" =~ ^[0-9a-f]{40}$ ]] || fail "invalid candidate SHA"
[[ "$BUILD_RUN_ID" =~ ^[0-9]+$ ]] || fail "invalid build run ID"
[[ "$STAGING" =~ ^auto-bump-staging-[0-9]+-[0-9]+$ ]] || fail "invalid staging branch"
[[ -f publish/manifest.json ]] || fail "missing verified manifest"
jq -e --arg sha "$CANDIDATE_SHA" --argjson run "$BUILD_RUN_ID" \
    '.candidate_sha == $sha and .build_run_id == $run and (.files | length > 0)' \
    publish/manifest.json >/dev/null || fail "manifest does not identify this candidate and build"
cp publish/manifest.json publish/feed/release-manifest.json

# 完整验证来源校验：用 GitHub API 证明 candidate 经过了全部验证
#（assemble dae/daed、audit、单构建、16 目标矩阵），且每项验证的都是该 SHA。
# verification.json 只做关联，证明来自 API。fail-closed，发生在改动 main 之前。
MANIFEST_PATH="$PWD/publish/manifest.json" \
    bash "$(dirname "$0")/verify-candidate.sh"

git fetch -q origin refs/heads/main
remote_main=$(git ls-remote origin refs/heads/main | cut -f1)
[[ "$remote_main" = "$BASE_SHA" || "$remote_main" = "$CANDIDATE_SHA" ]] || fail "main moved; candidate must be rebuilt"
# 冻结语义：candidate 由 tag 标识，不再依赖 staging 分支位置。
# staging 分支在冻结后可能已移动（新同步开始），不影响本次晋升。
candidate_tag_sha=$(git ls-remote origin "refs/tags/candidate/${CANDIDATE_SHA}" | cut -f1)
[[ "$candidate_tag_sha" = "$CANDIDATE_SHA" ]] || fail "candidate tag missing or moved"
git fetch -q origin "$CANDIDATE_SHA"
git merge-base --is-ancestor "$BASE_SHA" "$CANDIDATE_SHA" || fail "candidate does not descend from its base"

aggregate_workflow=$(GH_TOKEN="$AGGREGATE_FEED_TOKEN" gh api \
    'repos/kenzok8/openwrt-clashoo/contents/.github/workflows/aggregate-feed.yml?ref=main' \
    -H 'Accept: application/vnd.github.raw+json') || fail "cannot read aggregate workflow"
grep -Fq 'candidate_sha:' <<< "$aggregate_workflow" || fail "aggregate workflow lacks candidate identity gate"
grep -Fq 'build_run_id:' <<< "$aggregate_workflow" || fail "aggregate workflow lacks build identity gate"

version=$(git show "$CANDIDATE_SHA:ci/pins.env" | sed -n 's/^DAE_VERSION=//p')
[[ "$version" =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}$ ]] || fail "invalid candidate version"
tag="v${version}-${CANDIDATE_SHA:0:7}"
remote_tag=$(git ls-remote --tags origin "refs/tags/$tag^{}" | cut -f1)
if [[ -z "$remote_tag" ]]; then
    remote_tag=$(git ls-remote --tags origin "refs/tags/$tag" | cut -f1)
fi
[[ -z "$remote_tag" || "$remote_tag" = "$CANDIDATE_SHA" ]] || fail "tag $tag points to another commit"
if [[ "$remote_main" = "$CANDIDATE_SHA" && -z "$remote_tag" ]]; then
    fail "main already advanced but tag is absent; requires manual inspection"
fi

# Stage and verify the exact candidate bytes before changing main or a release.
rclone_dir=$(mktemp -d)
trap 'rm -rf "$rclone_dir"' EXIT
chmod 700 "$rclone_dir"
cat > "$rclone_dir/rclone.conf" <<EOF
[r2]
type = s3
provider = Cloudflare
access_key_id = ${R2_ACCESS_KEY_ID}
secret_access_key = ${R2_SECRET_ACCESS_KEY}
endpoint = ${R2_ENDPOINT}
acl = private
no_check_bucket = true
EOF
chmod 600 "$rclone_dir/rclone.conf"
export RCLONE_CONFIG="$rclone_dir/rclone.conf"
stage="r2:${R2_BUCKET}/openwrt-feed/daed-candidates/${CANDIDATE_SHA}"
probe="r2:${R2_BUCKET}/openwrt-feed/daed-candidates/.write-probe-${GITHUB_RUN_ID:-$BUILD_RUN_ID}"
rclone copyto publish/manifest.json "$probe"
rclone deletefile "$probe"
# --checksum：按内容比对。promote 重试时本地 publish/ 是重新生成的，
# 文件 mtime 与 stage 里已上传的不同，只按时间戳比对会被 --immutable 误判为已修改。
rclone copy publish/ "$stage/" --immutable --checksum --fast-list
# verification.json 是 gate 写入 stage 的验证记录（元数据，不属于发布内容，
# 本地 publish/ 由构建产物生成、不含此文件），校验时排除。
rclone check publish/ "$stage/" --download --fast-list --exclude verification.json

# The unified feed also carries luci-app-daede from jell. Its version must not
# supersede this candidate after main and the tag have moved.
for candidate in publish/feed/*/*/luci-app-daede*.apk publish/feed/*/*/luci-app-daede*.ipk; do
    [[ -f "$candidate" ]] || continue
    relative=${candidate#publish/feed/}
    directory=${relative%/*}
    candidate_name=${candidate##*/}
    rclone lsf "r2:${R2_BUCKET}/openwrt-feed/jell/${directory}/" \
        --files-only --include 'luci-app-daede*' > "$rclone_dir/jell-package-list" || \
        fail "cannot inspect jell packages in $directory"
    while IFS= read -r existing_name; do
        [[ -n "$existing_name" ]] || continue
        newest=$(printf '%s\n%s\n' "$candidate_name" "$existing_name" | sort -V | tail -1)
        [[ "$newest" = "$candidate_name" ]] || \
            fail "jell has a newer luci-app-daede in $directory: $existing_name"
    done < "$rclone_dir/jell-package-list"
done

state="r2:${R2_BUCKET}/openwrt-feed/daed-release-state"
pending="$state/pending.json"
manifest_digest=$(sha256sum publish/manifest.json | cut -d' ' -f1)
jq -n --arg sha "$CANDIDATE_SHA" --arg base "$BASE_SHA" \
    --arg staging "$STAGING" --arg tag "$tag" \
    --arg digest "$manifest_digest" --argjson run "$BUILD_RUN_ID" \
    '{candidate_sha:$sha,base_sha:$base,staging:$staging,tag:$tag,build_run_id:$run,manifest_sha256:$digest}' \
    > "$rclone_dir/pending.json"
if rclone lsf "$state/" --files-only | grep -Fxq pending.json; then
    rclone cat "$pending" > "$rclone_dir/existing-pending.json"
    cmp -s "$rclone_dir/pending.json" "$rclone_dir/existing-pending.json" || \
        fail "another release is pending"
else
    rclone copyto "$rclone_dir/pending.json" "$pending" --immutable
    rclone cat "$pending" > "$rclone_dir/existing-pending.json"
    cmp -s "$rclone_dir/pending.json" "$rclone_dir/existing-pending.json" || \
        fail "pending release state differs after upload"
fi

if [[ "$remote_main" = "$BASE_SHA" ]]; then
    git config user.name "github-actions[bot]"
    git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
    git tag -a "$tag" "$CANDIDATE_SHA" -m "Release $tag"
    git -c credential.helper='!gh auth git-credential' push --atomic \
        --force-with-lease="refs/heads/main:$BASE_SHA" origin \
        "$CANDIDATE_SHA:refs/heads/main" "refs/tags/$tag:refs/tags/$tag"
    [[ "$(git ls-remote origin refs/heads/main | cut -f1)" = "$CANDIDATE_SHA" ]] || fail "main did not advance to candidate"
fi

notes="$rclone_dir/release-notes.md"
BASE="https://github.com/kenzok8/openwrt-daede/releases/download/${tag}"
ARCHS="aarch64_cortex-a53 aarch64_cortex-a72 aarch64_generic arm_cortex-a7_neon-vfpv4 arm_cortex-a9 arm_cortex-a9_neon i386_pentium4 x86_64"
cell_ipk() {
    pkg="$1"; arch="$2"; fallback="$3"
    f=$(ls publish/release/${pkg}_*_${arch}.ipk 2>/dev/null | head -1)
    [ -n "$f" ] && echo "[$(basename $f)](${BASE}/$(basename $f))" || echo "$fallback"
}
cell_apk() {
    pkg="$1"; arch="$2"
    f=$(ls publish/release/${pkg}-*-${arch}.apk 2>/dev/null | head -1)
    [ -n "$f" ] && echo "[$(basename $f)](${BASE}/$(basename $f))" || echo "—"
}
noarch_ipk() {
    pkg="$1"
    f=$(ls publish/release/${pkg}_*_all.ipk 2>/dev/null | head -1)
    [ -n "$f" ] && echo "[$(basename $f)](${BASE}/$(basename $f))" || echo "—"
}
{
    printf '# openwrt-daede %s\n\n' "$tag"
    printf 'Pinned upstream dae/daed release from candidate `%s`.\n\n' "$CANDIDATE_SHA"
    printf 'All 16 SDK targets passed the patch audit and package gate. Build run: %s.\n\n' "$BUILD_RUN_ID"
    echo "## Packages / 安装包"
    echo ""
    echo "## 📦 SDK 24.10 · 稳定版 (IPK)"
    echo ""
    echo "| 架构 | dae | daed | luci-app-daede |"
    echo "| :--- | :--- | :--- | :--- |"
    luci_fallback=$(noarch_ipk luci-app-daede)
    for arch in $ARCHS; do
        echo "| \`${arch}\` | $(cell_ipk dae $arch —) | $(cell_ipk daed $arch —) | $(cell_ipk luci-app-daede $arch "$luci_fallback") |"
    done
    echo ""
    echo "## 📦 SDK 25.12 · 稳定版 (APK)"
    echo ""
    echo "| 架构 | dae | daed | luci-app-daede |"
    echo "| :--- | :--- | :--- | :--- |"
    for arch in $ARCHS; do
        echo "| \`${arch}\` | $(cell_apk dae $arch) | $(cell_apk daed $arch) | $(cell_apk luci-app-daede $arch) |"
    done
} > "$notes"
if ! gh release view "$tag" >/dev/null 2>&1; then
    gh release create "$tag" --draft --verify-tag --target "$CANDIDATE_SHA" \
        --title "Release $tag" --notes-file "$notes"
fi
release_target=$(gh release view "$tag" --json targetCommitish --jq '.targetCommitish')
[[ "$release_target" = "$CANDIDATE_SHA" || "$release_target" = "$tag" ]] || fail "Release target differs from candidate"
for asset in publish/release/* publish/manifest.json; do
    [[ -f "$asset" ]] || fail "missing release asset"
    name=${asset##*/}
    if gh release view "$tag" --json assets --jq '.assets[].name' | grep -Fxq "$name"; then
        existing="$rclone_dir/$name"
        gh release download "$tag" --pattern "$name" --output "$existing"
        cmp -s "$asset" "$existing" || fail "Release asset differs: $name"
    else
        gh release upload "$tag" "$asset"
    fi
done
{
    find publish/release -maxdepth 1 -type f -printf '%f\n'
    printf 'manifest.json\n'
} | sort > "$rclone_dir/expected-assets"
gh release view "$tag" --json assets --jq '.assets[].name' | sort > "$rclone_dir/actual-assets"
diff -u "$rclone_dir/expected-assets" "$rclone_dir/actual-assets" || fail "Release has unexpected or missing assets"

feed="r2:${R2_BUCKET}/openwrt-feed/daed"
rclone sync publish/feed/ "$feed/" --checksum --fast-list --transfers 8 --checkers 16
rclone check publish/feed/ "$feed/" --download --fast-list

aggregate_url=$(GH_TOKEN="$AGGREGATE_FEED_TOKEN" gh workflow run aggregate-feed.yml \
    -R kenzok8/openwrt-clashoo --ref main \
    -f candidate_sha="$CANDIDATE_SHA" -f build_run_id="$BUILD_RUN_ID")
aggregate_run=${aggregate_url##*/}
[[ "$aggregate_run" =~ ^[0-9]+$ ]] || fail "cannot identify aggregate feed run: $aggregate_url"
GH_TOKEN="$AGGREGATE_FEED_TOKEN" gh run watch "$aggregate_run" \
    -R kenzok8/openwrt-clashoo --exit-status
gh release edit "$tag" --draft=false --prerelease=false
# 冻结 tag 已完成使命（v* tag + release 才是 durable 引用）；删掉防止累积。
# 失败不致命：prune 工作流会清理 7 天以上的残留 candidate tag。
git -c credential.helper='!gh auth git-credential' push origin \
    --delete "refs/tags/candidate/${CANDIDATE_SHA}" 2>/dev/null \
    || echo "warning: cannot delete candidate tag (non-fatal)"
# --checksum：promote 中断后重跑时文件已存在但内容相同，按内容比对可幂等。
rclone copyto "$rclone_dir/pending.json" "$state/completed/${CANDIDATE_SHA}.json" --immutable --checksum
rclone cat "$state/completed/${CANDIDATE_SHA}.json" > "$rclone_dir/completed.json"
cmp -s "$rclone_dir/pending.json" "$rclone_dir/completed.json" || fail "completion state differs"
rclone deletefile "$pending"
printf 'promoted %s from build %s\n' "$tag" "$BUILD_RUN_ID"
