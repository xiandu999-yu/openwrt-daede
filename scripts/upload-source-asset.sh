#!/bin/sh

set -eu

die() {
	printf '%s\n' "upload-source-asset: $*" >&2
	exit 1
}

[ "$#" -eq 3 ] || die "usage: upload-source-asset.sh <dae-src|daed-src> <tarball> <owner/repo>"
release=$1
tarball_path=$2
tarball=${tarball_path##*/}
repo=$3

case "$release" in
	dae-src|daed-src) ;;
	*) die "invalid source release: $release" ;;
esac
case "$repo" in
	*/*/*|/*|*/|*[![:print:]]*|*' '*) die "invalid repository: $repo" ;;
esac
case "$tarball" in
	"$release"-????.??.??-????????????.tar.gz) ;;
	*) die "invalid tarball name: $tarball" ;;
esac
name_rest=${tarball#"$release"-}
date_part=${name_rest%%-*}
hash_part=${name_rest#*-}
hash_part=${hash_part%.tar.gz}
case "$date_part" in
	[0-9][0-9][0-9][0-9].[0-9][0-9].[0-9][0-9]) ;;
	*) die "invalid tarball date: $tarball" ;;
esac
case "$hash_part" in
	''|*[!0-9a-f]*) die "invalid tarball digest suffix: $tarball" ;;
esac
[ "${#hash_part}" -eq 12 ] || die "invalid tarball digest suffix: $tarball"
[ -f "$tarball_path" ] || die "tarball does not exist: $tarball_path"

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/upload-source-asset.XXXXXX") || die "cannot create temporary directory"
trap 'rm -rf "$tmpdir"' EXIT HUP INT TERM

release_json=$tmpdir/release.json
if ! gh api "repos/$repo/releases/tags/$release" >"$release_json"; then
	die "could not query source release"
fi
if ! jq -e 'type == "object" and (.id | type == "number")' "$release_json" >/dev/null; then
	die "invalid source release response"
fi
if ! release_id=$(jq -er '.id | tostring' "$release_json"); then
	die "could not parse source release id"
fi

assets_raw=$tmpdir/assets.raw
assets_flat=$tmpdir/assets.flat
if ! gh api --paginate --slurp "repos/$repo/releases/$release_id/assets?per_page=100" >"$assets_raw"; then
	die "could not query source release assets"
fi
if ! jq -e '
	if type != "array" then error("response is not an array")
	elif length == 0 then []
	elif all(.[]; type == "array") then add
	else .
	end
	| if type == "array" then . else error("response is not an array") end
' "$assets_raw" >"$assets_flat"; then
	die "invalid source release assets response"
fi
if ! jq -e '
	all(.[];
		type == "object"
		and (.name | type == "string")
		and (.id | type == "number")
	)
' "$assets_flat" >/dev/null; then
	die "invalid source release asset metadata"
fi

matches=$tmpdir/matches.json
if ! jq -c --arg name "$tarball" '[.[] | select(.name == $name)]' "$assets_flat" >"$matches"; then
	die "could not parse source release assets"
fi
if ! jq -e 'length <= 1' "$matches" >/dev/null; then
	die "source release contains duplicate asset names"
fi

sha256_file() {
	file=$1
	if command -v sha256sum >/dev/null 2>&1; then
		if ! digest_line=$(sha256sum "$file"); then
			return 1
		fi
	else
		if ! digest_line=$(shasum -a 256 "$file"); then
			return 1
		fi
	fi
	printf '%s\n' "${digest_line%% *}"
}

local_digest=$(sha256_file "$tarball_path")
case "$local_digest" in
	''|*[!0-9a-f]*) die "could not calculate tarball digest" ;;
esac
[ "${#local_digest}" -eq 64 ] || die "could not calculate tarball digest"
local_prefix=${local_digest%${local_digest#????????????}}
[ "$local_prefix" = "$hash_part" ] || die "tarball digest does not match filename: $tarball"

match_count=$(jq -r 'length' "$matches")
if [ "$match_count" -eq 0 ]; then
	if ! gh release upload "$release" "$tarball_path" --repo "$repo"; then
		die "source asset upload failed"
	fi
	printf '%s\n' "upload-source-asset: uploaded $tarball"
	exit 0
fi

download=$tmpdir/downloaded.tar.gz
if ! gh release download "$release" --repo "$repo" --pattern "$tarball" --output "$download"; then
	die "could not download existing source asset"
fi
remote_digest=$(sha256_file "$download")
case "$remote_digest" in
	''|*[!0-9a-f]*) die "could not calculate existing asset digest" ;;
esac
[ "${#remote_digest}" -eq 64 ] || die "could not calculate existing asset digest"
if [ "$local_digest" != "$remote_digest" ]; then
	die "existing asset digest differs for $tarball"
fi
printf '%s\n' "upload-source-asset: reused $tarball"
