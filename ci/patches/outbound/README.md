# outbound patches (self-owned)

Fixes we carry on top of `OUTBOUND_COMMIT` because upstream has not merged them.
The assemble workflows apply every `NNNN-*.patch` here with `git apply` right
after fetching outbound; an empty directory is skipped.

## Current state: one patch

| patch | what | why it is here |
|-------|------|----------------|
| 0001 | SSR obfs reaches its cipher through `BufferedReaderConn` | fixes every SSR handshake; olicesx never merged it into `perf/complete-optimizations` |

### 0001 background

The shadowsocks stream layer passes its cipher down to the SSR obfs conn by type
asserting on the underlying conn. A TCP read-buffering change wrapped that conn
in `netproxy.BufferedReaderConn`, so both assertions stopped matching and every
SSR handshake failed with `outer conn did not init cipher of Obfs` (issue #52).
The fix peels transparent wrappers via the existing `IntrinsicConn` accessor.

The fix exists upstream as a side commit (`d5d9708`, later rebased to
`5797872`) that was never merged into the perf branch we track. Pinning
`OUTBOUND_COMMIT` at that side commit does not survive: `auto-bump.yml` runs
`gh repo sync ... --force`, which resets our fork's branch to olicesx's, and the
next bump moves `OUTBOUND_COMMIT` to a perf-branch commit without the fix. That
is exactly how it regressed on 2026-08-13 (`dae/daed 2026.08.13`) — the same
breakage as #52, five days after it was first fixed. Carrying it as a patch here
decouples the fix from both the fork branch and the pin.

The patch ships `ssr_cipher_test.go` with it:
`TestSSRObfsReceivesCipherThroughBufferedReaderConn` fails on an unpatched tree
and passes on a patched one, so a silent regression cannot come back unnoticed.

## Apply by hand

```sh
git checkout -B carry <OUTBOUND_COMMIT>
git apply ci/patches/outbound/*.patch
go test ./protocol/shadowsocks_stream/
```

## When upstream absorbs it

`git apply` fails loudly and the assemble build stops — that is the signal to
delete the patch file (and confirm `unwrapConn` really is in the new base).
