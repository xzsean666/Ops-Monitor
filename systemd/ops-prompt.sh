#!/usr/bin/env bash
# ==============================================================================
# /etc/profile.d/ops-prompt.sh: Ops-Monitor SSH 交互登录感知与提示探针
# 严格保证非交互 (SCP/SFTP/rsync/批处理) 100% 静默
# ==============================================================================

# 1. 严格检查交互式终端 (必须有 TTY 输入和输出，且非哑终端)
if [[ ! -t 0 || ! -t 1 ]] || [[ "${TERM:-dumb}" == "dumb" ]]; then
    return 0 2>/dev/null || exit 0
fi

# 2. 检查用户永久忽略标记 (~/.ops_ignore)
if [[ -f "$HOME/.ops_ignore" ]]; then
    return 0 2>/dev/null || exit 0
fi

# 3. 检查 Ops-Monitor 是否已安装
if command -v ops >/dev/null 2>&1 || [[ -x "/opt/ops-monitor/ops.sh" ]] || [[ -x "/usr/local/bin/ops" ]]; then
    # 已安装：打印快捷使用提示
    echo -e "\e[36m💡 [Ops-Monitor]\e[0m 输入 \e[1m\e[32mops\e[0m 查看系统实时看板，输入 \e[1m\e[32mops status\e[0m 查看健康体检。"
else
    # 未安装：仅在交互式登录时提示自举引导
    echo -e "\e[33m⚡ [Ops-Monitor]\e[0m 检测到本机未安装轻量级监控套件 Ops-Monitor。"
    read -t 10 -r -p "是否现在一键安装？[y/N/ignore]: " choice || choice="n"
    case "${choice}" in
        y|Y|yes|YES)
            if command -v curl >/dev/null 2>&1; then
                echo "正在拉取安装脚本..."
                curl -fsSL https://raw.githubusercontent.com/xzsean666/Ops-Monitor/main/install.sh | bash 2>/dev/null || echo "安装未完成。"
            fi
            ;;
        ignore|IGNORE)
            touch "$HOME/.ops_ignore"
            echo "已设置永久忽略登录提示 (可通过删除 ~/.ops_ignore 恢复)。"
            ;;
        *)
            ;;
    esac
fi
