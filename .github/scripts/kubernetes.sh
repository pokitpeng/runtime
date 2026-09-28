#!/bin/bash

set -eu

readonly ERR_CODE=127

readonly ARCH=${arch?}
readonly CRI_TYPE=${criType?}
readonly KUBE_TYPE=${kubeType:-k8s}
readonly KUBE_RAW=${kubeVersion?}
readonly KUBE="${KUBE_RAW#v}"
if [[ "${sealoslatest:-}" == latest ]]; then
  export sealosPatch="ghcr.io/labring/sealos-patch:latest"
  sealoslatest=$(until curl -sL "https://api.github.com/repos/labring/sealos/releases/latest" | grep tarball_url; do sleep 3; done | awk -F\" '{print $(NF-1)}' | awk -F/ '{print $NF}' | cut -dv -f2)
fi
readonly SEALOS=${sealoslatest?}
readonly SEALOS_PATCH="${sealosPatch:-}"

readonly KUBE_XY="${KUBE%.*}"
readonly SEALOS_XYZ="${SEALOS%%-*}"
if [[ "${SEALOS_XYZ//./}" -le 433 ]] && [[ $KUBE_TYPE == k3s ]] && [[ -z "$SEALOS_PATCH" ]]; then
  echo "INFO::skip $KUBE(build for k3s) when $SEALOS(sealos<=4.3.3)"
  exit
fi
readonly IMAGE_HUB_REGISTRY=${registry?}
readonly IMAGE_HUB_REPO=${repo?}
readonly IMAGE_HUB_USERNAME=${username?}
readonly IMAGE_HUB_PASSWORD=${password?}
readonly IMAGE_CACHE_NAME="ghcr.io/labring-actions/cache"
readonly CONTAINERD_VERSION="${CONTAINERD_VERSION:-1}"
KUBE_CACHE_VERSION="${KUBE%+*}"
if [[ "$CRI_TYPE" == containerd ]]; then
  case "$CONTAINERD_VERSION" in
    1|2.4.1) ;;
    *) echo "Unsupported containerd version: $CONTAINERD_VERSION" >&2; exit 1 ;;
  esac
  if [[ "$CONTAINERD_VERSION" == 2.4.1 ]]; then
    if [[ ! "$KUBE" =~ ^1\.(34|35|36|37)\.[0-9]+$ ]]; then
      echo "containerd 2.4.1: Kubernetes $KUBE is outside the candidate 1.34-1.37 matrix" >&2
      exit 1
    fi
    if [[ "$KUBE_XY" == 1.37 ]]; then
      echo "Kubernetes 1.37 cache base and cri-v1.37 are unavailable; build and pin both before enabling this minor" >&2
      exit 1
    fi
    # Use the .0 base only for cached image layers; stage checked patch-level
    # binaries and an updated kubeadm image list into our new rootfs layer.
    KUBE_CACHE_VERSION="$KUBE_XY.0"
  fi
fi
readonly KUBE_CACHE_VERSION

ROOT="/tmp/$(whoami)/build"
PATCH="/tmp/$(whoami)/patch"
sudo rm -rf "$ROOT" "$PATCH"
mkdir -p "$ROOT" "$PATCH"

cp -a "$CRI_TYPE"/* "$ROOT"
cp -a registry/* "$ROOT"
cp -a "$KUBE_TYPE"/* "$ROOT"

# debug for sealos run
{
  cp .github/scripts/waitRunning.sh "/tmp"
}

pushd "$ROOT"
mkdir -p bin cri opt images/shim

MOUNT_CRI=$(sudo buildah mount "$(sudo buildah from "$IMAGE_CACHE_NAME:cri-$ARCH")")
# Check support for kube-v1.26+
if [[ "${KUBE_XY//./}" -ge 126 ]] && [[ "${SEALOS_XYZ//./}" -le 413 ]] && [[ -z "$SEALOS_PATCH" ]]; then
  echo "INFO::skip $KUBE(kube>=1.26) when $SEALOS(sealos<=4.1.3)"
  echo https://kubernetes.io/blog/2022/11/18/upcoming-changes-in-kubernetes-1-26/#cri-api-removal
  exit
fi

# image-cri-shim sealctl
if [[ -n "${SEALOS_LOCAL_BIN_DIR:-}" ]]; then
  for file in sealos sealctl image-cri-shim; do
    test -x "$SEALOS_LOCAL_BIN_DIR/$file" || { echo "missing $file in SEALOS_LOCAL_BIN_DIR" >&2; exit 1; }
  done
  sudo install -m 0755 "$SEALOS_LOCAL_BIN_DIR/sealos" /usr/bin/sealos
  sudo cp -a "$SEALOS_LOCAL_BIN_DIR/sealctl" opt/
  sudo cp -a "$SEALOS_LOCAL_BIN_DIR/image-cri-shim" cri/
elif [[ -n "$SEALOS_PATCH" ]]; then
  rmdir "$PATCH"
  sudo docker run --rm -v "/usr/bin:/pwd" --entrypoint /bin/sh ghcr.io/labring/sealos:latest -c "cp -a /usr/bin/sealos /pwd"
  sudo cp -au "$(sudo buildah mount "$(sudo buildah from "$SEALOS_PATCH-$ARCH")")" "$PATCH"
  sudo chown -R "$(whoami)" "$PATCH"
  tree "$PATCH" || true
  sudo cp -au "$PATCH"/* .
else
  sudo docker run --rm -v "/usr/bin:/pwd" --entrypoint /bin/sh "$IMAGE_CACHE_NAME:sealos-v$SEALOS-amd64" -c "cp -a /sealos/sealos /pwd"
  MOUNT_SEALOS=$(sudo buildah mount "$(sudo buildah from "$IMAGE_CACHE_NAME:sealos-v$SEALOS-$ARCH")")
  sudo cp -au "$MOUNT_SEALOS"/sealos/image-cri-shim cri/
  sudo cp -au "$MOUNT_SEALOS"/sealos/sealctl opt/
fi
sudo sealos version

# crictl helm kubeadm,kubectl,kubelet conntrack registry and cri(kubelet)
MOUNT_KUBE=$(sudo buildah mount "$(sudo buildah from "$IMAGE_CACHE_NAME:kubernetes-v$KUBE_CACHE_VERSION-$ARCH")")
MOUNT_CRIO=$(sudo buildah mount "$(sudo buildah from "$IMAGE_CACHE_NAME:cri-v$KUBE_XY-$ARCH")")
MOUNT_TOOLS=$(sudo buildah mount "$(sudo buildah from "$IMAGE_CACHE_NAME:tools-$ARCH")")
sudo tar -xzf "$MOUNT_CRIO"/cri/crictl.tar.gz -C bin/
if [[ "$CRI_TYPE" == containerd && "$CONTAINERD_VERSION" == 2.4.1 ]]; then
  bash "$OLDPWD/.github/scripts/prepare-kubernetes-binaries.sh" "$KUBE" "$ARCH" "$ROOT"
fi
#sudo cp -au "$MOUNT_KUBE"/bin/{kubeadm,kubectl,kubelet} bin/
sudo cp -au "$MOUNT_CRI"/cri/conntrack bin/
sudo cp -au "$MOUNT_CRI"/cri/lsof opt/
sudo cp -au "$MOUNT_CRI"/cri/{registry,libseccomp.tar.gz} cri/
case $CRI_TYPE in
containerd)
  if [[ "${SEALOS_XYZ%%.*}" -ge 5 ]] && ! [[ "${KUBE_XY//./}" -ge 124 ]]; then
    echo "INFO::skip $KUBE(kube<1.24) when $SEALOS(sealos>=5)"
    exit
  fi
  IMAGE_KUBE=kubernetes
  sudo cp -au "$MOUNT_CRI"/cri/cri-containerd.tar.gz cri/
  if [[ "$CONTAINERD_VERSION" == 2.4.1 ]]; then
    # The legacy cache image is still used for runc/crun and other tools.
    sudo chown "$(id -u):$(id -g)" cri/cri-containerd.tar.gz
    bash "$OLDPWD/.github/scripts/prepare-containerd-v2.sh" "$ARCH" cri/cri-containerd.tar.gz
    cp -a etc/config-v4.toml.tmpl etc/config.toml.tmpl
    rm etc/config-v4.toml.tmpl
  else
    rm etc/config-v4.toml.tmpl
  fi
  ;;
cri-o)
  if [[ "${SEALOS_XYZ%%.*}" -ge 5 ]] && ! [[ "${KUBE_XY//./}" -ge 124 ]]; then
    echo "INFO::skip $KUBE(kube<1.24) when $SEALOS(sealos>=5)"
    exit
  fi
  IMAGE_KUBE=kubernetes-${CRI_TYPE//-/}
  sudo cp -au "$MOUNT_CRIO"/cri/cri-o.tar.gz cri/
  sudo cp -au "$MOUNT_CRIO"/cri/{install.crio,crio.files} cri/
  ;;
docker)
  if [[ "${SEALOS_XYZ%%.*}" -ge 5 ]] && ! [[ "${KUBE_XY//./}" -ge 126 ]]; then
    echo "INFO::skip $KUBE(kube<1.26) when $SEALOS(sealos>=5)"
    exit
  fi
  IMAGE_KUBE=kubernetes-$CRI_TYPE
  if [[ "${KUBE_XY//./}" -ge 126 ]]; then
    sudo cp -au "$MOUNT_CRI"/cri/cri-dockerd.tgz cri/
  else
    sudo cp -au "$MOUNT_CRI"/cri/cri-dockerd.tgzv125 cri/cri-dockerd.tgz
  fi
  DOCKER_XY=$(until curl -sL "https://github.com/kubernetes/kubernetes/raw/release-$KUBE_XY/build/dependencies.yaml" | yq '.dependencies[]|select(.name == "docker")|.version'; do sleep 3; done)
  case $DOCKER_XY in
  18.09 | 19.03 | 20.10)
    sudo cp -au "$MOUNT_CRI/cri/docker-$DOCKER_XY.tgz" cri/docker.tgz
    ;;
  *)
    sudo cp -au "$MOUNT_CRI/cri/docker.tgz" cri/
    ;;
  esac
  ;;
esac
if grep k3s <<<"$KUBE"; then
  IMAGE_KUBE=k3s
fi

# define ImageTag for kube
if [[ "${SEALOS//./}" =~ ^[0-9]+$ ]] && [[ -z "$SEALOS_PATCH" ]]; then
  readonly RELEASE=stable
  if [[ "$SEALOS" == "$(
    until curl -sL "https://api.github.com/repos/labring/sealos/releases/latest"; do sleep 3; done | grep tarball_url | awk -F\" '{print $(NF-1)}' | awk -F/ '{print $NF}' | cut -dv -f2
  )" ]]; then
    IMAGE_PUSH_NAME=(
      "$IMAGE_HUB_REGISTRY/$IMAGE_HUB_REPO/$IMAGE_KUBE:v${KUBE%+*}-$ARCH"
      "$IMAGE_HUB_REGISTRY/$IMAGE_HUB_REPO/$IMAGE_KUBE:v${KUBE%+*}-$SEALOS-$ARCH"
    )
  else
    IMAGE_PUSH_NAME=(
      "$IMAGE_HUB_REGISTRY/$IMAGE_HUB_REPO/$IMAGE_KUBE:v${KUBE%+*}-$SEALOS-$ARCH"
    )
  fi
else
  readonly RELEASE=unstable
  IMAGE_PUSH_NAME=(
    "$IMAGE_HUB_REGISTRY/$IMAGE_HUB_REPO/$IMAGE_KUBE:v$KUBE_XY-$ARCH"
  )
fi

# Experimental v2 images must not overwrite the legacy Kubernetes tags.
if [[ "$CRI_TYPE" == containerd && "$CONTAINERD_VERSION" == 2.4.1 ]]; then
  for i in "${!IMAGE_PUSH_NAME[@]}"; do
    IMAGE_PUSH_NAME[$i]="${IMAGE_PUSH_NAME[$i]}-containerd2.4.1"
  done
fi

### Sealed ###
sudo chown -R "$(whoami)" "$ROOT"
### Sealed ###

# define ImageTag for lvscare(ipvs)
if rmdir "$PATCH" 2>/dev/null; then
  ipvsImage="ghcr.io/labring/lvscare:v$SEALOS"
  echo "$ipvsImage" >images/shim/LvscareImageList
else
  ipvsImage="$(cat images/shim/*vscare*)"
  rm -fv images/shim/*vscare*
fi

# update Kubefile
if [[ "$CRI_TYPE" == containerd && "$CONTAINERD_VERSION" == 2.4.1 ]]; then
  pauseImage=$(grep /pause: images/shim/DefaultImageList)
else
  pauseImage=$(sudo grep /pause: "$MOUNT_KUBE/images/shim/DefaultImageList")
fi
if grep k3s <<<"$KUBE"; then
  rm -fv bin/crictl bin/conntrack cri/cri-containerd.tar.gz cri/libseccomp.tar.gz opt/lsof
  case $ARCH in
  amd64)
    readonly K3S_DL="https://github.com/k3s-io/k3s/releases/download/v$KUBE/k3s"
    ;;
  arm64)
    readonly K3S_DL="https://github.com/k3s-io/k3s/releases/download/v$KUBE/k3s-$ARCH"
    ;;
  esac
  curl -fsSLo bin/k3s "$K3S_DL"
  chmod a+x bin/k3s
  curl -fsSL "https://github.com/k3s-io/k3s/releases/download/v$KUBE/k3s-images.txt" | sed "/pause:/d" >images/shim/DefaultImageList
  echo "$pauseImage" >>images/shim/DefaultImageList
else
  sed -E "s#^FROM .+#FROM $IMAGE_CACHE_NAME:kubernetes-v$KUBE_CACHE_VERSION-$ARCH#" Kubefile >"Kubefile.$(uname)"
  mv -fv "Kubefile.$(uname)" Kubefile
fi

#### building ###
IMAGE_BUILD="$IMAGE_HUB_REGISTRY/$IMAGE_HUB_REPO/$IMAGE_KUBE:build-$(date +%s)"
find . -type f -exec file {} \; | grep -E "(executable,|/ld-)" | awk -F: '{print $1}' | grep -vE "\.so" | while IFS='' read -r elf; do echo "${elf}"; done | xargs chmod a+x
tree -L 5
# shellcheck disable=SC2046
sudo sealos build $(
  cat <<EOF | while read -r kv; do echo --label="$kv"; done | xargs
sealos.io.type=rootfs
sealos.io.version=v1beta1
version=v${KUBE%+*}
image=$ipvsImage
EOF
) $(
  cat <<EOF | while read -r kv; do echo --env="$kv"; done | xargs
defaultVIP=10.103.97.2
sandboxImage=${pauseImage#*/}
EOF
) -t "$IMAGE_BUILD" --platform "linux/$ARCH" .

# Test-only local build: no cluster changes or registry pushes.
if [[ "${SEALOS_TEST_BUILD_ONLY:-}" == 1 ]]; then
  echo "SEALOS_TEST_BUILD_IMAGE=$IMAGE_BUILD"
  exit 0
fi

# debug for sealos run with amd64
if [[ amd64 == "$ARCH" ]]; then
  if [[ unstable == "$RELEASE" ]]; then
    dpkg-query --search "$(command -v containerd)" "$(command -v docker)"
    sudo apt-get remove -y moby-buildx moby-cli moby-compose moby-containerd moby-engine \
      docker docker-ce docker-ce-cli docker-engine docker.io containerd containerd.io &>/dev/null
    sudo rm -rf /var/run/docker.sock /run/containerd/containerd.sock
    sudo mv -fv /etc/cni/net.d/* /etc/cni
    sudo systemctl unmask "${CRI_TYPE//-/}" || true
    sudo mkdir -p /sys/fs/cgroup/systemd
    sudo mount -t cgroup -o none,name=systemd cgroup /sys/fs/cgroup/systemd || true
    if ! sudo sealos run "$IMAGE_BUILD" labring/flannel:0.24.0; then
      if grep k3s <<<"$KUBE"; then
        export SEALOS_RUN="skipped::k3s"
      else
        case $CRI_TYPE in
        containerd)
          "$CRI_TYPE" --version
          ;;
        cri-o)
          "${CRI_TYPE//-/}" --version
          ;;
        docker)
          "$CRI_TYPE" info
          ;;
        esac
        sudo crictl ps -a || true
        if [[ "${KUBE_XY//./}" -le 116 ]]; then
          export SEALOS_RUN="skipped::compatibility"
          echo "Incompatible versions $KUBE($CRI_TYPE) fail testing"
          echo "Incompatible versions $KUBE($CRI_TYPE) fail testing"
          echo "Incompatible versions $KUBE($CRI_TYPE) fail testing"
        else
          export SEALOS_RUN="failed"
          systemctl status "${CRI_TYPE//-/}" || true
          journalctl -xeu "${CRI_TYPE//-/}" || true
          systemctl status kubelet || true
          journalctl -xeu kubelet || true
        fi
      fi
    else
      export SEALOS_RUN="succeed::run"
      mkdir -p "$HOME/.kube"
      if grep k3s <<<"$KUBE"; then
        sudo cp /etc/rancher/k3s/k3s.yaml "$HOME/.kube/config"
      else
        sudo cp /etc/kubernetes/admin.conf "$HOME/.kube/config"
      fi
      sudo chown "$(whoami)" "$HOME/.kube/config"
      if ! bash /tmp/waitRunning.sh 1 3; then
        echo "TIMEOUT(waitRunning)"
      fi
    fi
    sudo sealos reset --force
  else
    export SEALOS_RUN="stable::build"
  fi
else
  export SEALOS_RUN="skipped::arm64"
fi

# Check images for local
{
  while IFS= read -r i; do
    j=${i%/_manifests*}
    image=${j##*/}
    while IFS= read -r tag; do echo "$image:$tag"; done < <(sudo ls "$i")
  done < <(sudo find registry -name tags -type d | grep _manifests/tags) | sort
}

echo "SEALOS_STATUS => $SEALOS_RUN"
echo "SEALOS_STATUS => $SEALOS_RUN"
echo "SEALOS_STATUS => $SEALOS_RUN"

# Check images for push
{
  if ! [[ "$SEALOS_RUN" =~ failed ]]; then
    echo -n "ImageArchitecture: "
    if sudo buildah inspect "$IMAGE_BUILD" | yq .OCIv1.architecture | grep "$ARCH" ||
      sudo buildah inspect "$IMAGE_BUILD" | yq .Docker.architecture | grep "$ARCH"; then
      echo -n >"/tmp/$IMAGE_HUB_REGISTRY.v$KUBE-$ARCH.images"
      # check images
      for IMAGE_NAME in "${IMAGE_PUSH_NAME[@]}"; do
        if [[ "${allBuild:-}" != true ]]; then
          if [[ "${KUBE_XY//./}" -eq 127 ]]; then
            echo "$IMAGE_NAME" >>"/tmp/$IMAGE_HUB_REGISTRY.v$KUBE-$ARCH.images"
            continue
          fi
          case $IMAGE_HUB_REGISTRY in
          docker.io)
            if until curl -sL "https://hub.docker.com/v2/repositories/$IMAGE_HUB_REPO/$IMAGE_KUBE/tags/${IMAGE_NAME##*:}"; do sleep 3; done |
              grep digest >/dev/null; then
              if ! grep "$KUBE" <<<"${IMAGE_NAME##*:}" &>/dev/null; then
                # always push for kube 1.xx(DEV)
                echo "$IMAGE_NAME" >>"/tmp/$IMAGE_HUB_REGISTRY.v$KUBE-$ARCH.images"
              else
                echo "$IMAGE_NAME already existed"
              fi
            else
              echo "$IMAGE_NAME" >>"/tmp/$IMAGE_HUB_REGISTRY.v$KUBE-$ARCH.images"
            fi
            ;;
          *)
            if sudo buildah pull "$IMAGE_NAME" &>/dev/null && grep "$KUBE" <<<"${IMAGE_NAME##*:}" &>/dev/null; then
              echo "$IMAGE_NAME already existed"
            else
              echo "$IMAGE_NAME" >>"/tmp/$IMAGE_HUB_REGISTRY.v$KUBE-$ARCH.images"
            fi
            ;;
          esac
        else
          echo "$IMAGE_NAME" >>"/tmp/$IMAGE_HUB_REGISTRY.v$KUBE-$ARCH.images"
        fi
      done
      # push images
      if [[ -s "/tmp/$IMAGE_HUB_REGISTRY.v$KUBE-$ARCH.images" ]]; then
        sudo sealos login -u "$IMAGE_HUB_USERNAME" -p "$IMAGE_HUB_PASSWORD" "$IMAGE_HUB_REGISTRY"
        while read -r IMAGE_NAME; do
          sudo sealos tag "$IMAGE_BUILD" "$IMAGE_NAME"
          until sudo sealos push "$IMAGE_NAME"; do sleep 3; done
        done <"/tmp/$IMAGE_HUB_REGISTRY.v$KUBE-$ARCH.images"
        sudo sealos logout "$IMAGE_HUB_REGISTRY"
      fi
    else
      sudo buildah inspect "$IMAGE_BUILD" | yq -CP
      echo "ERROR::TARGETARCH for sealos build"
      exit $ERR_CODE
    fi
  fi
}

sudo buildah containers --format "{{.ContainerID}}({{.ContainerName}}) {{.ImageID}}({{.ImageName}})"
sudo buildah umount --all &>/dev/null
sudo buildah rm --all &>/dev/null
sudo buildah images

if [[ "$SEALOS_RUN" =~ failed ]]; then
  exit $ERR_CODE
fi
