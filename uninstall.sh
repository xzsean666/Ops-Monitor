#!/usr/bin/env bash
# ==============================================================================
# Ops-Monitor 卸载与清理脚本 (uninstall.sh)
# 支持保留配置卸载与 --purge 完全清除模式
# ==============================================================================
set -euo pipefail

INSTALL_DIR="/opt/ops-monitor"
CONFIG_DIR="/etc/ops-monitor"
DATA_DIR="/var/log/ops-monitor"

echo "=== 正在开始卸载 Ops-Monitor ==="

# 1. Root 权限检查
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "[ERROR] 卸载需要 root 权限，请使用 sudo bash uninstall.sh 重新执行。" >&2
    exit 1
fi

PURGE=0
if [[ "${1:-}" == "--purge" ]]; then
    PURGE=1
fi

# 2. 停止并禁用服务
if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
    echo "[INFO] 停止并注销 ops-daemon.service..."
    systemctl stop ops-daemon.service 2>/dev/null || true
    systemctl disable ops-daemon.service 2>/dev/null || true
    rm -f /etc/systemd/system/ops-daemon.service
    systemctl daemon-reload || true
fi

# 3. 移除系统软链接与探针
echo "[INFO] 清理软链接与登录探针..."
rm -f /usr/local/bin/ops
rm -f /etc/profile.d/ops-prompt.sh

# 4. 删除核心程序目录
echo "[INFO] 移除核心程序目录 ${INSTALL_DIR}..."
rm -rf "${INSTALL_DIR}"

# 5. 处理配置与数据目录
if [[ "${PURGE}" -eq 1 ]]; then
    echo "[INFO] 执行 --purge: 彻底清理配置与历史日志目录..."
    rm -rf "${CONFIG_DIR}"
    rm -rf "${DATA_DIR}"
else
    echo "[INFO] 已保留配置文件 (${CONFIG_DIR}) 与历史监控数据 (${DATA_DIR})。"
    echo "       如需彻底清除请使用: sudo bash uninstall.sh --purge"
fi

echo "=== Ops-Monitor 卸载完成 ==="
