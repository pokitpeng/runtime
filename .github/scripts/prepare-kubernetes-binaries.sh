#!/usr/bin/env bash
# Stage patch-level Kubernetes tools when the upstream cache contains only .0.
# Run on the build host (amd64); the target binary architecture may be arm64.
set -euo pipefail
[[ $# -eq 3 ]] || { echo "usage: $0 1.34.12 amd64|arm64 ROOT" >&2; exit 2; }
version=$1 arch=$2 root=$3
[[ "$version" =~ ^1\.(34|35|36|37)\.[0-9]+$ ]] || { echo "invalid Kubernetes version: $version" >&2; exit 2; }
[[ "$arch" == amd64 || "$arch" == arm64 ]] || { echo "invalid architecture: $arch" >&2; exit 2; }
mkdir -p "$root/bin" "$root/images/shim"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fetch_binary() {
  local binary=$1 platform=$2 dest=$3 url sum
  url="https://dl.k8s.io/release/v${version}/bin/linux/${platform}/${binary}"
  curl -fLsS --retry 3 --max-time 180 -o "$dest" "$url"
  sum=$(curl -fLsS --retry 3 --max-time 30 "${url}.sha256")
  [[ "$sum" =~ ^[0-9a-f]{64}$ ]] || { echo "invalid SHA256 for $url" >&2; exit 1; }
  echo "$sum  $dest" | sha256sum -c -
  chmod 755 "$dest"
}
for binary in kubeadm kubelet kubectl; do
  fetch_binary "$binary" "$arch" "$work/$binary-$arch"
  mv "$work/$binary-$arch" "$root/bin/$binary"
done
if [[ "$arch" == amd64 ]]; then
  kubeadm="$root/bin/kubeadm"
else
  fetch_binary kubeadm amd64 "$work/kubeadm-amd64"
  kubeadm="$work/kubeadm-amd64"
fi
"$kubeadm" config images list --kubernetes-version "v$version" > "$work/DefaultImageList"
grep -q '^registry.k8s.io/pause:' "$work/DefaultImageList" || { echo "pause image missing in kubeadm output" >&2; exit 1; }
mv "$work/DefaultImageList" "$root/images/shim/DefaultImageList"
