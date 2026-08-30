#!/usr/bin/env bash
# ==============================================================================
# Ops-Monitor 本地开发软链接安装/卸载工具 (link.sh)
# 将当前仓库源码 ops.sh 软链接至 bin 目录，实现修改代码实时生效（热更新开发模式）
# ==============================================================================
set -euo pipefail

_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPS_SCRIPT="${_ROOT}/ops.sh"

# 确保脚本具备可执行权限
chmod +x "${OPS_SCRIPT}" "${_ROOT}/lib/"*.sh "${_ROOT}/build-deb.sh" "${_ROOT}/install.sh" "${_ROOT}/uninstall.sh" 2>/dev/null || true

# 1. 卸载软链接模式 (--unlink)
if [[ "${1:-}" == "--unlink" || "${1:-}" == "unlink" || "${1:-}" == "--remove" ]]; then
    echo "=== 正在清理 Ops-Monitor 软链接 ==="
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        rm -f /usr/local/bin/ops
        echo "✔ 已成功移除全局软链接: /usr/local/bin/ops"
    else
        rm -f "${HOME}/.local/bin/ops"
        echo "✔ 已成功移除用户软链接: ${HOME}/.local/bin/ops"
    fi
    exit 0
fi

echo "=== 正在将 Ops-Monitor (ops) 软链接至系统可执行路径 ==="

# 2. 判断安装目标位置（root -> /usr/local/bin, 普通用户 -> ~/.local/bin）
if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    TARGET_BIN="/usr/local/bin/ops"
    ln -sf "${OPS_SCRIPT}" "${TARGET_BIN}"
    echo -e "✔ [系统级全局软链接成功] ${TARGET_BIN} -> ${OPS_SCRIPT}"
else
    TARGET_DIR="${HOME}/.local/bin"
    TARGET_BIN="${TARGET_DIR}/ops"
    mkdir -p "${TARGET_DIR}"
    ln -sf "${OPS_SCRIPT}" "${TARGET_BIN}"
    echo -e "✔ [用户级免root软链接成功] ${TARGET_BIN} -> ${OPS_SCRIPT}"

    # 检查当前 PATH 是否包含 ~/.local/bin
    if [[ ":$PATH:" != *":${TARGET_DIR}:"* ]]; then
        echo ""
        echo "⚠️  注意: 您的当前终端 PATH 尚未包含 ${TARGET_DIR}。"
        echo "   可运行以下命令将其加入 PATH（或添加到 ~/.bashrc）："
        echo "   export PATH=\"\$HOME/.local/bin:\$PATH\""
    fi
fi

echo ""
echo "🎉 软链接安装完成！当前已进入【实时开发模式】。"
echo "   后续你在本仓库中修改任何代码，终端执行 ops 时都会即时生效，无需重新安装！"
echo ""
echo "👉 测试命令: ops --version"
