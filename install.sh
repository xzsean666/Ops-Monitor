#!/usr/bin/env bash
# ==============================================================================
# Ops-Monitor 源码一键安装脚本 (install.sh)
# 支持本地执行与 curl -fsSL ... | bash 远程自举安装
# ==============================================================================
set -euo pipefail

VERSION="1.0.0"
INSTALL_DIR="/opt/ops-monitor"
CONFIG_DIR="/etc/ops-monitor"
DATA_DIR="/var/log/ops-monitor"

echo "=== 正在开始安装 Ops-Monitor v${VERSION} ==="

# 1. Root 权限检查
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "[ERROR] 安装需要 root 权限，请使用 sudo bash install.sh 重新执行。" >&2
    exit 1
fi

# 2. 确定源码目录 (支持 curl 管道下载与本地目录安装)
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")"
TEMP_CLONE=""

if [[ -z "${SRC_DIR}" ]] || [[ ! -f "${SRC_DIR}/ops.sh" ]]; then
    echo "[INFO] 检测到远程管道执行，正在拉取最新源码仓库..."
    TEMP_CLONE="/tmp/ops_install_src_$$"
    mkdir -p "${TEMP_CLONE}"
    curl -fsSL "https://github.com/xzsean666/Ops-Monitor/archive/refs/heads/main.tar.gz" | tar -xz -C "${TEMP_CLONE}" --strip-components=1
    SRC_DIR="${TEMP_CLONE}"
fi

cleanup() {
    if [[ -n "${TEMP_CLONE}" && -d "${TEMP_CLONE}" ]]; then
        rm -rf "${TEMP_CLONE}"
    fi
}
trap cleanup EXIT

# 3. 创建目标目录
echo "[INFO] 正在部署核心程序文件至 ${INSTALL_DIR}..."
mkdir -p "${INSTALL_DIR}/config" "${INSTALL_DIR}/lib" "${INSTALL_DIR}/systemd"
mkdir -p "${CONFIG_DIR}"
mkdir -p "${DATA_DIR}/current" "${DATA_DIR}/state"

# 4. 同步核心文件
cp -f "${SRC_DIR}/ops.sh" "${INSTALL_DIR}/ops.sh"
chmod 755 "${INSTALL_DIR}/ops.sh"

cp -f "${SRC_DIR}/config/ops.conf.default" "${INSTALL_DIR}/config/ops.conf.default"
cp -f "${SRC_DIR}/lib/"*.sh "${INSTALL_DIR}/lib/"
chmod 644 "${INSTALL_DIR}/lib/"*.sh

cp -f "${SRC_DIR}/systemd/ops-daemon.service" "${INSTALL_DIR}/systemd/ops-daemon.service"
cp -f "${SRC_DIR}/systemd/ops-prompt.sh" "${INSTALL_DIR}/systemd/ops-prompt.sh"

# 5. 配置文件初始化 (保留已有配置)
if [[ ! -f "${CONFIG_DIR}/ops.conf" ]]; then
    echo "[INFO] 初始化默认配置文件: ${CONFIG_DIR}/ops.conf"
    cp -f "${SRC_DIR}/config/ops.conf.default" "${CONFIG_DIR}/ops.conf"
else
    echo "[INFO] 保留已有自定义配置文件: ${CONFIG_DIR}/ops.conf"
fi
chmod 0600 "${CONFIG_DIR}/ops.conf"

# 6. 建立全局 CLI 软链接
echo "[INFO] 注册系统命令 /usr/local/bin/ops..."
mkdir -p /usr/local/bin
ln -sf "${INSTALL_DIR}/ops.sh" /usr/local/bin/ops

# 7. 部署 SSH 登录探针
echo "[INFO] 部署 SSH 登录感知探针至 /etc/profile.d/ops-prompt.sh..."
mkdir -p /etc/profile.d
cp -f "${INSTALL_DIR}/systemd/ops-prompt.sh" /etc/profile.d/ops-prompt.sh
chmod 755 /etc/profile.d/ops-prompt.sh

# 8. 注册并启动 Systemd 服务
if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
    echo "[INFO] 注册并启动 ops-daemon.service..."
    mkdir -p /etc/systemd/system
    cp -f "${INSTALL_DIR}/systemd/ops-daemon.service" /etc/systemd/system/ops-daemon.service
    systemctl daemon-reload
    systemctl enable ops-daemon.service
    systemctl restart ops-daemon.service
fi

echo ""
echo "================================================================================"
echo "🎉 Ops-Monitor 安装成功！"
echo "  - 终端命令: ops (进入实时看板) 或 ops status (健康体检)"
echo "  - 配置文件: ${CONFIG_DIR}/ops.conf"
echo "  - 服务状态: systemctl status ops-daemon"
echo "================================================================================"
