#!/usr/bin/env bash
# 在 Rocky Linux 8（容器或主机）上从源码编译 OpsKat，产出 RPM + 便携 tar.gz。
#
# 容器用法（GitHub Actions 走的就是这条）：
#   docker run --rm -i \
#     -v "$PWD/out:/out" -v "$PWD/ci:/ci:ro" \
#     -e REF=v1.14.0 rockylinux:8 bash /ci/build-opskat-el8.sh
#
# 主机用法（需要 root，会安装编译依赖）：
#   sudo REF=v1.14.0 OUT="$PWD/out" bash ci/build-opskat-el8.sh
set -euo pipefail

REF="${REF:-v1.14.0}"
MAKE_RPM="${MAKE_RPM:-true}"
GO_VERSION="${GO_VERSION:-1.26.10}"
NODE_VERSION="${NODE_VERSION:-22.23.4}"
SRC="${SRC:-/tmp/src}"
OUT="${OUT:-/out}"
RPMTOP="${RPMTOP:-/tmp/rpmbuild}"
STAGE="${STAGE:-/tmp/stage}"

log() { printf '\n==> %s\n' "$*"; }

if [ "$(id -u)" -ne 0 ]; then
  echo "请用 root 运行：需要 dnf 安装编译依赖，并写入 /usr/local。" >&2
  exit 1
fi

log "安装 Rocky 8 编译依赖"
dnf -y install --setopt=install_weak_deps=False \
  curl gawk gzip sed grep tar xz git make \
  gcc gcc-c++ pkgconf-pkg-config \
  gtk3-devel webkit2gtk3-devel rpm-build

# 上游 CI 在 ubuntu-22.04 上编译（glibc 2.34），这里固定用 EL8 自带的
# gcc/glibc 编译，产物的最高 GLIBC 符号版本就是 2.28。
log "安装 Go ${GO_VERSION}"
curl -fsSL --retry 3 "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tgz
rm -rf /usr/local/go
tar -C /usr/local -xzf /tmp/go.tgz
ln -sf /usr/local/go/bin/go /usr/local/bin/go
ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt

log "安装 Node.js ${NODE_VERSION}"
curl -fsSL --retry 3 "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" -o /tmp/node.tar.xz
tar -C /opt -xJf /tmp/node.tar.xz
for bin in node npm npx corepack; do
  ln -sf "/opt/node-v${NODE_VERSION}-linux-x64/bin/${bin}" "/usr/local/bin/${bin}"
done

export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
export CI=true
export HOME=/root
export GOPATH=/root/go
export GOTOOLCHAIN=auto
export PATH="/usr/local/go/bin:/root/go/bin:/opt/node-v${NODE_VERSION}-linux-x64/bin:${PATH}"

log "工具链版本"
gcc --version | head -n1
pkg-config --modversion gtk+-3.0 webkit2gtk-4.0
go version
node --version

log "克隆 opskat ${REF}"
rm -rf "$SRC"
git clone --depth 1 --branch "$REF" https://github.com/opskat/opskat.git "$SRC"
cd "$SRC"
COMMIT="$(git rev-parse --short HEAD)"
VERSION="$(printf '%s' "$REF" | sed -E 's/^v//; s/-/./g; s/[^0-9A-Za-z._~]//g')"
[ -n "$VERSION" ] || VERSION="0.0.0"
log "version=${VERSION} commit=${COMMIT}"

# CLI 版本跟随 go.mod，避免上游升级 Wails 后 CLI 与库版本不匹配。
WAILS_VERSION="${WAILS_VERSION:-$(awk '$1 == "github.com/wailsapp/wails/v2" { print $2; exit }' go.mod)}"
[ -n "$WAILS_VERSION" ] || WAILS_VERSION="v2.16.0"
log "安装 Wails CLI ${WAILS_VERSION}"
go install "github.com/wailsapp/wails/v2/cmd/wails@${WAILS_VERSION}"
ln -sf /root/go/bin/wails /usr/local/bin/wails

LDFLAGS="-s -w -X github.com/cago-frame/cago/configs.Version=${REF} -X github.com/opskat/opskat/internal/buildinfo.CommitID=${COMMIT}"

log "编译 opsctl（一份嵌入桌面端，一份作为独立 CLI）"
go build -ldflags "$LDFLAGS" -o ./internal/embedded/opsctl_bin ./cmd/opsctl/
go build -ldflags "$LDFLAGS" -o /tmp/opsctl ./cmd/opsctl/

log "编译桌面端（cgo + GTK3 + WebKitGTK 4.0）"
NODE_OPTIONS=--max-old-space-size=4096 \
  wails build -platform linux/amd64 -ldflags="$LDFLAGS" -tags embed_opsctl
test -x build/bin/opskat

log "准备打包目录"
rm -rf "$RPMTOP" "$STAGE"
mkdir -p "$RPMTOP"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS} "$OUT" "$STAGE/opskat"
install -m0755 build/bin/opskat "$RPMTOP/SOURCES/opskat"
install -m0755 /tmp/opsctl "$RPMTOP/SOURCES/opsctl"
install -m0644 build/appicon.png "$RPMTOP/SOURCES/opskat.png"

cat > "$RPMTOP/SOURCES/opskat.desktop" <<'DESKTOP'
[Desktop Entry]
Name=OpsKat
Comment=All-in-one server ops workstation
Exec=/usr/bin/opskat
Icon=opskat
Terminal=false
Type=Application
Categories=Development;System;Utility;
StartupNotify=true
DESKTOP

log "生成便携 tar.gz"
install -m0755 build/bin/opskat "$STAGE/opskat/opskat"
install -m0755 /tmp/opsctl "$STAGE/opskat/opsctl"
install -m0644 "$RPMTOP/SOURCES/opskat.desktop" "$STAGE/opskat/opskat.desktop"
install -m0644 "$RPMTOP/SOURCES/opskat.png" "$STAGE/opskat/opskat.png"
cat > "$STAGE/opskat/README.txt" <<'TXT'
OpsKat 便携版（在 Rocky Linux 8 / glibc 2.28 上编译）

依赖：
  sudo dnf install -y gtk3 webkit2gtk3

运行：
  ./opskat
  ./opsctl --help

加入桌面菜单（可选）：
  mkdir -p ~/.local/share/applications
  sed "s#Exec=/usr/bin/opskat#Exec=$PWD/opskat#" opskat.desktop \
    > ~/.local/share/applications/opskat.desktop
TXT
tar -C "$STAGE" -czf "$OUT/opskat-${VERSION}-linux-x86_64.tar.gz" opskat

if [ "$MAKE_RPM" = "true" ]; then
  log "生成 RPM"
  cat > "$RPMTOP/SPECS/opskat.spec" <<SPEC
%global debug_package %{nil}
%global _build_id_links none
Name:           opskat
Version:        ${VERSION}
Release:        1.el8
Summary:        All-in-one server ops workstation
License:        GPL-3.0-only
URL:            https://github.com/opskat/opskat
Source0:        opskat
Source1:        opsctl
Source2:        opskat.desktop
Source3:        opskat.png
BuildArch:      x86_64
Requires:       gtk3
Requires:       webkit2gtk3
%description
OpsKat 是集 SSH/RDP/VNC、数据库、Redis、Kafka、Kubernetes、
S3 等能力于一体的桌面运维工作台。
%install
install -Dpm0755 %{SOURCE0} %{buildroot}%{_bindir}/opskat
install -Dpm0755 %{SOURCE1} %{buildroot}%{_bindir}/opsctl
install -Dpm0644 %{SOURCE2} %{buildroot}%{_datadir}/applications/opskat.desktop
install -Dpm0644 %{SOURCE3} %{buildroot}%{_datadir}/icons/hicolor/256x256/apps/opskat.png
%post
gtk-update-icon-cache -f -t %{_datadir}/icons/hicolor >/dev/null 2>&1 || :
update-desktop-database %{_datadir}/applications >/dev/null 2>&1 || :
%postun
gtk-update-icon-cache -f -t %{_datadir}/icons/hicolor >/dev/null 2>&1 || :
update-desktop-database %{_datadir}/applications >/dev/null 2>&1 || :
%files
%{_bindir}/opskat
%{_bindir}/opsctl
%{_datadir}/applications/opskat.desktop
%{_datadir}/icons/hicolor/256x256/apps/opskat.png
SPEC
  rpmbuild --define "_topdir $RPMTOP" -bb "$RPMTOP/SPECS/opskat.spec"
  cp "$RPMTOP"/RPMS/x86_64/*.rpm "$OUT"/
fi

log "生成校验和"
(
  cd "$OUT"
  : > SHA256SUMS.txt
  for f in ./*.rpm ./*.tar.gz; do
    [ -e "$f" ] || continue
    sha256sum "${f#./}" >> SHA256SUMS.txt
  done
)

log "完成，产物："
ls -lh "$OUT"
