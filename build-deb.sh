#!/usr/bin/env bash
# ==============================================================================
# Ops-Monitor Debian/Ubuntu 打包脚本 (build-deb.sh)
# 自动化构建符合 Debian 规范的 ops-monitor_<version>_all.deb
# ==============================================================================
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="1.0.0"
PACKAGE_NAME="ops-monitor"
DEB_NAME="${PACKAGE_NAME}_${VERSION}_all.deb"
DIST_DIR="${BASE_DIR}/dist"
BUILD_ROOT="/tmp/ops_deb_build_$$"

cleanup() {
    rm -rf "${BUILD_ROOT}"
}
trap cleanup EXIT

echo "=== [BUILD] 开始构建 Ops-Monitor Debian 安装包 (v${VERSION}) ==="

# 1. 准备构建目录
mkdir -p "${DIST_DIR}"
mkdir -p "${BUILD_ROOT}/DEBIAN"
mkdir -p "${BUILD_ROOT}/opt/ops-monitor/config"
mkdir -p "${BUILD_ROOT}/opt/ops-monitor/lib"
mkdir -p "${BUILD_ROOT}/opt/ops-monitor/systemd"
mkdir -p "${BUILD_ROOT}/etc/ops-monitor"
mkdir -p "${BUILD_ROOT}/etc/systemd/system"
mkdir -p "${BUILD_ROOT}/etc/profile.d"
mkdir -p "${BUILD_ROOT}/usr/local/bin"

# 2. 复制 DEBIAN 控制文件与维护脚本
cp "${BASE_DIR}/debian/control" "${BUILD_ROOT}/DEBIAN/control"
cp "${BASE_DIR}/debian/conffiles" "${BUILD_ROOT}/DEBIAN/conffiles"
cp "${BASE_DIR}/debian/postinst" "${BUILD_ROOT}/DEBIAN/postinst"
cp "${BASE_DIR}/debian/prerm" "${BUILD_ROOT}/DEBIAN/prerm"
cp "${BASE_DIR}/debian/postrm" "${BUILD_ROOT}/DEBIAN/postrm"

chmod 755 "${BUILD_ROOT}/DEBIAN/postinst" "${BUILD_ROOT}/DEBIAN/prerm" "${BUILD_ROOT}/DEBIAN/postrm"
chmod 644 "${BUILD_ROOT}/DEBIAN/control" "${BUILD_ROOT}/DEBIAN/conffiles"

# 3. 复制核心程序文件
cp "${BASE_DIR}/ops.sh" "${BUILD_ROOT}/opt/ops-monitor/ops.sh"
chmod 755 "${BUILD_ROOT}/opt/ops-monitor/ops.sh"

cp "${BASE_DIR}/config/ops.conf.default" "${BUILD_ROOT}/opt/ops-monitor/config/ops.conf.default"
cp "${BASE_DIR}/config/ops.conf.default" "${BUILD_ROOT}/etc/ops-monitor/ops.conf"
chmod 600 "${BUILD_ROOT}/etc/ops-monitor/ops.conf"

cp "${BASE_DIR}/lib/"*.sh "${BUILD_ROOT}/opt/ops-monitor/lib/"
chmod 644 "${BUILD_ROOT}/opt/ops-monitor/lib/"*.sh

cp "${BASE_DIR}/systemd/ops-daemon.service" "${BUILD_ROOT}/opt/ops-monitor/systemd/ops-daemon.service"
cp "${BASE_DIR}/systemd/ops-prompt.sh" "${BUILD_ROOT}/opt/ops-monitor/systemd/ops-prompt.sh"
chmod 644 "${BUILD_ROOT}/opt/ops-monitor/systemd/ops-daemon.service"
chmod 755 "${BUILD_ROOT}/opt/ops-monitor/systemd/ops-prompt.sh"

# 4. 创建系统软链接
ln -sf /opt/ops-monitor/ops.sh "${BUILD_ROOT}/usr/local/bin/ops"
cp -f "${BASE_DIR}/systemd/ops-daemon.service" "${BUILD_ROOT}/etc/systemd/system/ops-daemon.service"
cp -f "${BASE_DIR}/systemd/ops-prompt.sh" "${BUILD_ROOT}/etc/profile.d/ops-prompt.sh"

# 5. 执行打包构建
TARGET_DEB="${DIST_DIR}/${DEB_NAME}"
if command -v dpkg-deb >/dev/null 2>&1; then
    dpkg-deb --build --root-owner-group "${BUILD_ROOT}" "${TARGET_DEB}"
else
    echo "[WARN] 未找到 dpkg-deb，尝试使用 tar/ar 基础构建..."
    # 纯 POSIX 备用构建
    (
        cd "${BUILD_ROOT}"
        tar -czf "${BUILD_ROOT}/control.tar.gz" -C "${BUILD_ROOT}/DEBIAN" .
        rm -rf "${BUILD_ROOT}/DEBIAN"
        tar -czf "${BUILD_ROOT}/data.tar.gz" .
        echo "2.0" > "${BUILD_ROOT}/debian-binary"
        ar r "${TARGET_DEB}" "${BUILD_ROOT}/debian-binary" "${BUILD_ROOT}/control.tar.gz" "${BUILD_ROOT}/data.tar.gz"
    )
fi

echo "=== [BUILD] 打包成功! ==="
echo "产物路径: ${TARGET_DEB}"
if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${TARGET_DEB}"
fi
