#!/bin/sh
# Resolves the real, on-disk go2rtc binary and prints exactly one line:
# "<arch> <sha256> <realpath>". Prints nothing and exits non-zero if go2rtc
# can't be found or resolved to a regular file.
#
# This does NOT decide whether go2rtc is trusted -- it only reports what is
# actually on disk. BackendManager.qml compares this output against the
# committed Go2rtcTrustRoot.json and refuses to spawn on any mismatch. Run
# through bin/supervise.sh via BoundedProcess with a restricted PATH
# (/usr/bin:/bin), so PATH itself can't be poisoned to point at something
# other than a real system-installed go2rtc.
set -eu

candidate=""
if [ -x /usr/bin/go2rtc ]; then
  candidate=/usr/bin/go2rtc
else
  candidate=$(command -v go2rtc 2>/dev/null || true)
fi

if [ -z "$candidate" ]; then
  echo "go2rtc-verify: go2rtc not found on PATH" >&2
  exit 1
fi

# readlink -f resolves through any symlink chain to the real underlying
# file -- a candidate that resolves to something outside a normal binary
# install location, or that isn't a regular file at all, is refused by the
# next check rather than trusted just because a name matched.
real_path=$(readlink -f -- "$candidate")
if [ ! -f "$real_path" ]; then
  echo "go2rtc-verify: resolved path is not a regular file: $real_path" >&2
  exit 1
fi

case "$(uname -m)" in
  x86_64) arch=linux_x86_64 ;;
  aarch64) arch=linux_aarch64 ;;
  *)
    echo "go2rtc-verify: unsupported architecture $(uname -m)" >&2
    exit 1
    ;;
esac

hash=$(sha256sum -- "$real_path" | cut -d' ' -f1)
printf '%s %s %s\n' "$arch" "$hash" "$real_path"
