#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/upload-source-asset-selftest.XXXXXX")
trap 'rm -rf "$tmpdir"' EXIT HUP INT TERM

mock_dir=$tmpdir/bin
mkdir -p "$mock_dir"
cat >"$mock_dir/gh" <<'EOF'
#!/bin/sh
set -eu

case_name=${MOCK_CASE:?}
log=${MOCK_LOG:?}
asset_name=${ASSET_NAME:?}
if [ "${1:-}" = api ]; then
	[ "$case_name" != api-fail ] || exit 1
	if [ "$#" -eq 2 ] && [ "$2" = repos/acme/openwrt-daede/releases/tags/dae-src ]; then
		endpoint=release
	elif [ "$#" -eq 4 ] && [ "$2" = --paginate ] && [ "$3" = --slurp ] && \
		[ "$4" = repos/acme/openwrt-daede/releases/123/assets?per_page=100 ]; then
		endpoint=assets
	else
		printf '%s\n' 'selftest: unexpected gh api arguments' >&2
		exit 1
	fi
	if [ "$case_name" = bad-release ] && [ "$endpoint" = release ]; then
		printf '%s\n' '{bad release json'
		exit 0
	fi
	if [ "$case_name" = bad-assets ] && [ "$endpoint" = assets ]; then
		printf '%s\n' '{bad assets json'
		exit 0
	fi
	if [ "$endpoint" = release ]; then
		printf '%s\n' '{"id":123}'
	elif [ "$case_name" = new ]; then
		printf '%s\n' '[[]]'
	else
		printf '[[{"id":1,"name":"other.tar.gz"}],[{"id":456,"name":"%s"}]]\n' "$asset_name"
	fi
	exit 0
fi
if [ "${1:-}" = release ] && [ "${2:-}" = upload ]; then
	[ "$#" -eq 6 ] || exit 1
	[ "$3" = dae-src ] || exit 1
	[ "$4" = "${EXPECTED_PATH:?}" ] || exit 1
	[ "$5" = --repo ] || exit 1
	[ "$6" = acme/openwrt-daede ] || exit 1
	case " $* " in *' --clobber '*|*' delete-asset '*) exit 1 ;; esac
	printf '%s\n' upload >>"$log"
	exit 0
fi
if [ "${1:-}" = release ] && [ "${2:-}" = download ]; then
	[ "$#" -eq 9 ] || exit 1
	[ "$3" = dae-src ] || exit 1
	[ "$4" = --repo ] || exit 1
	[ "$5" = acme/openwrt-daede ] || exit 1
	[ "$6" = --pattern ] || exit 1
	[ "$7" = "${EXPECTED_TARBALL:?}" ] || exit 1
	[ "$8" = --output ] || exit 1
	output=
	previous=
	for arg in "$@"; do
		if [ "${previous:-}" = --output ]; then output=$arg; fi
		previous=$arg
	done
	[ -n "$output" ] || exit 1
	case " $* " in *' --clobber '*|*' delete-asset '*) exit 1 ;; esac
	if [ "$case_name" = mismatch ]; then
		printf '%s\n' different >"$output"
	else
		printf '%s\n' matching >"$output"
	fi
	exit 0
fi
exit 1
EOF
chmod +x "$mock_dir/gh"

tarball_content=$tmpdir/content
printf '%s\n' matching >"$tarball_content"
if command -v sha256sum >/dev/null 2>&1; then
	digest_line=$(sha256sum "$tarball_content")
else
	digest_line=$(shasum -a 256 "$tarball_content")
fi
digest=${digest_line%% *}
digest_prefix=${digest%${digest#????????????}}
tarball=$tmpdir/dae-src-2026.09.19-$digest_prefix.tar.gz
cp "$tarball_content" "$tarball"

run_case() {
	case_name=$1
	expected=$2
	log=$tmpdir/$case_name.log
	: >"$log"
	if [ "$expected" = fail ]; then
		if PATH="$mock_dir:$PATH" MOCK_CASE="$case_name" MOCK_LOG="$log" ASSET_NAME="${tarball##*/}" EXPECTED_TARBALL="${tarball##*/}" EXPECTED_PATH="$tarball" \
			sh "$script_dir/upload-source-asset.sh" dae-src "$tarball" acme/openwrt-daede; then
			printf '%s\n' "selftest: $case_name unexpectedly succeeded" >&2
			exit 1
		fi
	else
		PATH="$mock_dir:$PATH" MOCK_CASE="$case_name" MOCK_LOG="$log" ASSET_NAME="${tarball##*/}" EXPECTED_TARBALL="${tarball##*/}" EXPECTED_PATH="$tarball" \
			sh "$script_dir/upload-source-asset.sh" dae-src "$tarball" acme/openwrt-daede
	fi
	case "$expected" in
		upload) [ "$(sed -n '1p' "$log")" = upload ] ;;
		none) [ ! -s "$log" ] ;;
		fail) [ ! -s "$log" ] ;;
	esac
}

run_case new upload
run_case same none
run_case mismatch fail
run_case api-fail fail
run_case bad-release fail
run_case bad-assets fail

invalid=$tmpdir/dae-src-2026.09.19-aaaaaaaaaaaa.tar.gz
cp "$tarball_content" "$invalid"
log=$tmpdir/invalid.log
: >"$log"
if PATH="$mock_dir:$PATH" MOCK_CASE=new MOCK_LOG="$log" ASSET_NAME="${invalid##*/}" EXPECTED_TARBALL="${invalid##*/}" \
	sh "$script_dir/upload-source-asset.sh" dae-src "$invalid" acme/openwrt-daede; then
	printf '%s\n' 'selftest: wrong suffix unexpectedly succeeded' >&2
	exit 1
fi
[ ! -s "$log" ]

invalid_manual=$tmpdir/dae-src-manual.tar.gz
printf '%s\n' invalid >"$invalid_manual"
log=$tmpdir/invalid-manual.log
: >"$log"
if PATH="$mock_dir:$PATH" MOCK_CASE=new MOCK_LOG="$log" ASSET_NAME="${invalid_manual##*/}" \
	sh "$script_dir/upload-source-asset.sh" dae-src "$invalid_manual" acme/openwrt-daede; then
	printf '%s\n' 'selftest: invalid manual name unexpectedly succeeded' >&2
	exit 1
fi
[ ! -s "$log" ]

if grep -Eq 'delete-asset|--clobber' "$script_dir/upload-source-asset.sh"; then
	printf '%s\n' 'selftest: upload script contains a forbidden destructive option' >&2
	exit 1
fi

printf '%s\n' 'upload-source-asset selftest: PASS'
