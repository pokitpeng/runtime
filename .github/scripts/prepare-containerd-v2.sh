#!/usr/bin/env bash
# Replace the containerd binaries inside an existing cri-containerd.tar.gz,
# retaining separately packaged runc/crun. Experimental: does not publish an image.
set -euo pipefail
[[ $# -eq 2 ]] || { echo "usage: $0 amd64|arm64 path/to/cri-containerd.tar.gz" >&2; exit 2; }
arch=$1 archive=$2
case "$arch" in
  amd64) checksum=d65eda6a188aac1006848d8060099be88ba9c4bcddbfd9a23a961194710d0dd4 ;;
  arm64) checksum=67f9b0a81c7140aaf15fe69053e88175270fadd33aeaffc1b9017123c1f55cea ;;
  *) echo "unsupported architecture: $arch" >&2; exit 2 ;;
esac
[[ -f "$archive" ]] || { echo "missing archive: $archive" >&2; exit 1; }
archive=$(realpath "$archive")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fL --retry 3 -o "$tmp/official.tar.gz" "https://github.com/containerd/containerd/releases/download/v2.4.1/containerd-2.4.1-linux-$arch.tar.gz"
echo "$checksum  $tmp/official.tar.gz" | sha256sum -c -
mkdir -p "$tmp/root/usr/bin" "$tmp/official"
tar -xzf "$archive" -C "$tmp/root"
tar -xzf "$tmp/official.tar.gz" -C "$tmp/official"
[[ -x "$tmp/root/usr/bin/runc" ]] || { echo "base archive missing runc" >&2; exit 1; }
# Remove old containerd binaries, not externally packaged runc/crun.
find "$tmp/root/usr/bin" -maxdepth 1 -type f \( -name 'containerd*' -o -name 'ctr' \) -delete
cp -a "$tmp/official/bin/." "$tmp/root/usr/bin/"
"$tmp/root/usr/bin/containerd" --version | grep -F 'v2.4.1'
tar -czf "$tmp/repacked.tar.gz" -C "$tmp/root" usr
mv "$tmp/repacked.tar.gz" "$archive"
