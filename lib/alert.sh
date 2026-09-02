#!/usr/bin/env bash
# ==============================================================================
# Ops-Monitor 告警规则评估与状态机引擎 (lib/alert.sh)
# 实现 NORMAL -> SUSPECTED -> ALERTED -> COOLDOWN 四状态机转换
# 支持连续超限防抖 (Debounce) 与静默冷却 (Cooldown)
# ==============================================================================

_ALERT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${_ALERT_LIB_DIR}/common.sh"
# shellcheck source=config_mgr.sh
source "${_ALERT_LIB_DIR}/config_mgr.sh"
# shellcheck source=collector.sh
source "${_ALERT_LIB_DIR}/collector.sh"
# shellcheck source=webhook.sh
source "${_ALERT_LIB_DIR}/webhook.sh"
unset _ALERT_LIB_DIR

# 状态机持久化文件路径
OPS_ALERT_STATE_FILE="${OPS_ALERT_STATE_FILE:-${OPS_STATE_DATA_DIR}/alert.state}"

# 内存状态字典
declare -g -A OPS_ALERT_STATE 2>/dev/null || true

# ------------------------------------------------------------------------------
# 状态持久化加载与保存
# ------------------------------------------------------------------------------
_ops_alert_load_state() {
    OPS_ALERT_STATE=()
    if [[ -f "${OPS_ALERT_STATE_FILE}" ]]; then
        while IFS= read -r line || [[ -n "${line}" ]]; do
            [[ -z "${line}" || "${line}" =~ ^# ]] && continue
            if [[ "${line}" =~ ^([A-Za-z0-9_]+)=(.*)$ ]]; then
                OPS_ALERT_STATE["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
            fi
        done < "${OPS_ALERT_STATE_FILE}"
    fi
}

_ops_alert_save_state() {
    ops_ensure_dirs || return "${OPS_EXIT_PERM_ERR}"
    
    local tmp_file="${OPS_ALERT_STATE_FILE}.tmp.$$"
    {
        echo "# Ops-Monitor 告警状态机缓存 ($(date '+%Y-%m-%d %H:%M:%S'))"
        for k in "${!OPS_ALERT_STATE[@]}"; do
            echo "${k}=${OPS_ALERT_STATE[${k}]}"
        done
    } > "${tmp_file}"

    mv -f "${tmp_file}" "${OPS_ALERT_STATE_FILE}"
    ops_secure_file "${OPS_ALERT_STATE_FILE}"
}

# ------------------------------------------------------------------------------
# 单指标状态机评估 (NORMAL -> SUSPECTED -> ALERTED -> COOLDOWN)
# ------------------------------------------------------------------------------
_ops_alert_eval_metric() {
    local name="$1"                # CPU, MEM, DISK, NET_RX, NET_TX
    local current_val="$2"         # 浮点数 (如 88.5 或 52.3)
    local threshold="$3"           # 浮点数 (如 85.0 或 50)
    local consecutive_req="${4:-1}" # 触发所需连续次数 (如 3)
    local cooldown_min="${5:-30}"  # 冷却时长 (分钟)
    local now_ts="$6"              # 当前时间戳 (秒)
    local unit="${7:-%}"           # 指标单位 (% 或 MB/s)

    local state_key="${name}_STATE"
    local count_key="${name}_CONSECUTIVE_COUNT"
    local last_alert_key="${name}_LAST_ALERT_TIME"

    local current_state="${OPS_ALERT_STATE[${state_key}]:-NORMAL}"
    local count="${OPS_ALERT_STATE[${count_key}]:-0}"
    local last_alert_time="${OPS_ALERT_STATE[${last_alert_key}]:-0}"

    # 阈值为 0 或负数表示不启用该指标告警
    local is_disabled
    is_disabled=$(awk -v t="${threshold}" 'BEGIN { print (t <= 0) ? 1 : 0 }')
    if [[ "${is_disabled}" -eq 1 ]]; then
        OPS_ALERT_STATE["${state_key}"]="NORMAL"
        OPS_ALERT_STATE["${count_key}"]="0"
        return 0
    fi

    # 浮点数比较: current_val >= threshold
    local is_exceeded
    is_exceeded=$(awk -v v="${current_val}" -v t="${threshold}" 'BEGIN { print (v >= t) ? 1 : 0 }')

    if [[ "${is_exceeded}" -eq 1 ]]; then
        # 超出阈值情况处理
        if [[ "${current_state}" == "COOLDOWN" ]]; then
            local cooldown_sec=$(( cooldown_min * 60 ))
            local elapsed=$(( now_ts - last_alert_time ))

            if [[ "${elapsed}" -ge "${cooldown_sec}" ]]; then
                # 冷却期结束，若依然超限，再次触发告警
                ops_log_warn "[告警触发] ${name} 持续超限 (${current_val}${unit} >= ${threshold}${unit})，冷却期结束再次告警"
                ops_webhook_broadcast "${name}" "${current_val}" "${threshold}" "$(date '+%Y-%m-%d %H:%M:%S')" 0 "${unit}"
                OPS_ALERT_STATE["${state_key}"]="COOLDOWN"
                OPS_ALERT_STATE["${last_alert_key}"]="${now_ts}"
                OPS_ALERT_STATE["${count_key}"]="${consecutive_req}"
            else
                # 仍在冷却期内，保持静默
                ops_log_debug "${name} 处于冷却期中 (${elapsed}s/${cooldown_sec}s)，抑制报警"
                OPS_ALERT_STATE["${state_key}"]="COOLDOWN"
            fi
        elif [[ "${current_state}" == "NORMAL" ]]; then
            if [[ "${consecutive_req}" -le 1 ]]; then
                # 无需防抖，直接触发
                ops_log_warn "[告警触发] ${name} 超限 (${current_val}${unit} >= ${threshold}${unit})，立即告警"
                ops_webhook_broadcast "${name}" "${current_val}" "${threshold}" "$(date '+%Y-%m-%d %H:%M:%S')" 0 "${unit}"
                OPS_ALERT_STATE["${state_key}"]="COOLDOWN"
                OPS_ALERT_STATE["${count_key}"]="1"
                OPS_ALERT_STATE["${last_alert_key}"]="${now_ts}"
            else
                # 进入怀疑态 (SUSPECTED)
                ops_log_info "[防抖判定] ${name} 首次超限 (${current_val}${unit} >= ${threshold}${unit})，进入怀疑状态 (1/${consecutive_req})"
                OPS_ALERT_STATE["${state_key}"]="SUSPECTED"
                OPS_ALERT_STATE["${count_key}"]="1"
            fi
        elif [[ "${current_state}" == "SUSPECTED" ]]; then
            count=$(( count + 1 ))
            if [[ "${count}" -ge "${consecutive_req}" ]]; then
                # 连续超限达到要求，触发告警并进入冷却
                ops_log_warn "[告警触发] ${name} 连续超限达 ${count} 次 (${current_val}${unit} >= ${threshold}${unit})，触发告警"
                ops_webhook_broadcast "${name}" "${current_val}" "${threshold}" "$(date '+%Y-%m-%d %H:%M:%S')" 0 "${unit}"
                OPS_ALERT_STATE["${state_key}"]="COOLDOWN"
                OPS_ALERT_STATE["${count_key}"]="${count}"
                OPS_ALERT_STATE["${last_alert_key}"]="${now_ts}"
            else
                ops_log_info "[防抖判定] ${name} 持续超限 (${current_val}${unit} >= ${threshold}${unit})，怀疑中 (${count}/${consecutive_req})"
                OPS_ALERT_STATE["${state_key}"]="SUSPECTED"
                OPS_ALERT_STATE["${count_key}"]="${count}"
            fi
        fi
    else
        # 指标正常 (低于阈值)
        if [[ "${current_state}" == "COOLDOWN" ]] || [[ "${current_state}" == "ALERTED" ]]; then
            # 从异常状态恢复
            ops_log_info "[告警恢复] ${name} 已恢复正常 (${current_val}${unit} < ${threshold}${unit})"
            ops_webhook_broadcast "${name}" "${current_val}" "${threshold}" "$(date '+%Y-%m-%d %H:%M:%S')" 1 "${unit}"
        fi

        # 重置回 NORMAL
        OPS_ALERT_STATE["${state_key}"]="NORMAL"
        OPS_ALERT_STATE["${count_key}"]="0"
    fi
}

# ------------------------------------------------------------------------------
# 综合评估所有指标 (CPU, MEM, DISK, NET_RX, NET_TX)
# ------------------------------------------------------------------------------
ops_alert_evaluate_all() {
    local cpu_val="${1:-}"
    local mem_val="${2:-}"
    local disk_val="${3:-}"
    local rx_val=""
    local tx_val=""
    local now_ts=""

    if [[ $# -ge 6 ]]; then
        rx_val="${4:-0}"
        tx_val="${5:-0}"
        now_ts="${6:-$(date +%s)}"
    elif [[ $# -eq 4 ]]; then
        # 兼容 4 参数调用 (cpu, mem, disk, ts)
        rx_val="0"
        tx_val="0"
        now_ts="${4:-$(date +%s)}"
    elif [[ $# -eq 5 ]]; then
        rx_val="${4:-0}"
        tx_val="${5:-0}"
        now_ts="$(date +%s)"
    else
        rx_val="0"
        tx_val="0"
        now_ts="$(date +%s)"
    fi

    # 若未传参则通过采集引擎采集
    if [[ -z "${cpu_val}" || -z "${mem_val}" || -z "${disk_val}" ]]; then
        local raw_tsv
        raw_tsv=$(ops_collect_metrics 1)
        IFS=$'\t' read -r now_ts cpu_val mem_val disk_val rx_val tx_val <<< "${raw_tsv}"
    fi

    # 计算网络吞吐量 (KB/s 转换为 MB/s)
    local rx_mb tx_mb
    rx_mb=$(awk -v k="${rx_val:-0}" 'BEGIN { printf "%.2f", (k / 1024.0) }')
    tx_mb=$(awk -v k="${tx_val:-0}" 'BEGIN { printf "%.2f", (k / 1024.0) }')

    _ops_alert_load_state

    # 读取配置阈值
    local cpu_thresh mem_thresh disk_thresh cpu_consecutive cooldown_min
    local net_rx_thresh net_tx_thresh net_consecutive
    cpu_thresh=$(ops_config_get "ALERT_CPU_THRESHOLD" "85")
    cpu_consecutive=$(ops_config_get "ALERT_CPU_CONSECUTIVE" "3")
    mem_thresh=$(ops_config_get "ALERT_MEM_THRESHOLD" "90")
    disk_thresh=$(ops_config_get "ALERT_DISK_THRESHOLD" "85")
    net_rx_thresh=$(ops_config_get "ALERT_NET_RX_THRESHOLD_MB" "50")
    net_tx_thresh=$(ops_config_get "ALERT_NET_TX_THRESHOLD_MB" "50")
    net_consecutive=$(ops_config_get "ALERT_NET_CONSECUTIVE" "3")
    cooldown_min=$(ops_config_get "ALERT_COOLDOWN_MINUTES" "30")

    # 分别评估指标
    _ops_alert_eval_metric "CPU" "${cpu_val}" "${cpu_thresh}" "${cpu_consecutive}" "${cooldown_min}" "${now_ts}" "%"
    _ops_alert_eval_metric "MEM" "${mem_val}" "${mem_thresh}" 1 "${cooldown_min}" "${now_ts}" "%"
    _ops_alert_eval_metric "DISK" "${disk_val}" "${disk_thresh}" 1 "${cooldown_min}" "${now_ts}" "%"
    _ops_alert_eval_metric "NET_RX" "${rx_mb}" "${net_rx_thresh}" "${net_consecutive}" "${cooldown_min}" "${now_ts}" " MB/s"
    _ops_alert_eval_metric "NET_TX" "${tx_mb}" "${net_tx_thresh}" "${net_consecutive}" "${cooldown_min}" "${now_ts}" " MB/s"

    _ops_alert_save_state
}

# ------------------------------------------------------------------------------
# 查询当前系统告警整体状态
# 返回 NORMAL / WARN / CRITICAL
# ------------------------------------------------------------------------------
ops_alert_get_overall_status() {
    _ops_alert_load_state

    local cpu_state="${OPS_ALERT_STATE[CPU_STATE]:-NORMAL}"
    local mem_state="${OPS_ALERT_STATE[MEM_STATE]:-NORMAL}"
    local disk_state="${OPS_ALERT_STATE[DISK_STATE]:-NORMAL}"
    local net_rx_state="${OPS_ALERT_STATE[NET_RX_STATE]:-NORMAL}"
    local net_tx_state="${OPS_ALERT_STATE[NET_TX_STATE]:-NORMAL}"

    if [[ "${cpu_state}" == "COOLDOWN" || "${mem_state}" == "COOLDOWN" || "${disk_state}" == "COOLDOWN" || "${net_rx_state}" == "COOLDOWN" || "${net_tx_state}" == "COOLDOWN" ]]; then
        echo "CRITICAL"
    elif [[ "${cpu_state}" == "SUSPECTED" || "${mem_state}" == "SUSPECTED" || "${disk_state}" == "SUSPECTED" || "${net_rx_state}" == "SUSPECTED" || "${net_tx_state}" == "SUSPECTED" ]]; then
        echo "WARN"
    else
        echo "NORMAL"
    fi
}

# ------------------------------------------------------------------------------
# 探测守护进程运行状态
# ------------------------------------------------------------------------------
_ops_alert_get_daemon_status() {
    local is_running=0
    local detail="未在运行"
    local pid=""

    if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q "ops-daemon.service"; then
        if systemctl is-active ops-daemon.service >/dev/null 2>&1; then
            is_running=1
            local enabled_str="已设开机自启"
            if ! systemctl is-enabled ops-daemon.service >/dev/null 2>&1; then
                enabled_str="未设开机自启"
            fi
            detail="Systemd / ${enabled_str}"
        else
            detail="Systemd 未启动"
        fi
    else
        local pid_file="${OPS_RUN_DIR}/ops-daemon.pid"
        if [[ -f "${pid_file}" ]]; then
            pid=$(cat "${pid_file}" 2>/dev/null || echo "")
            if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
                is_running=1
                detail="后台进程 (PID: ${pid})"
            else
                detail="未在运行"
            fi
        else
            detail="未在运行"
        fi
    fi

    if [[ "${is_running}" -eq 1 ]]; then
        echo "1|${detail}"
    else
        echo "0|${detail}"
    fi
}

# ------------------------------------------------------------------------------
# 极简修改单项告警阈值
# ------------------------------------------------------------------------------
_ops_alert_set_metric() {
    local target="$1"
    local val="$2"
    local config_key=""
    local name=""
    local unit="%"

    case "${target,,}" in
        cpu)
            config_key="ALERT_CPU_THRESHOLD"
            name="CPU 使用率"
            ;;
        mem|memory)
            config_key="ALERT_MEM_THRESHOLD"
            name="内存使用率"
            ;;
        disk)
            config_key="ALERT_DISK_THRESHOLD"
            name="磁盘使用率"
            ;;
        rx|net_rx|net-rx)
            config_key="ALERT_NET_RX_THRESHOLD_MB"
            name="网络入站 (RX)"
            unit=" MB/s"
            ;;
        tx|net_tx|net-tx)
            config_key="ALERT_NET_TX_THRESHOLD_MB"
            name="网络出站 (TX)"
            unit=" MB/s"
            ;;
        cooldown)
            config_key="ALERT_COOLDOWN_MINUTES"
            name="告警冷却时间"
            unit=" 分钟"
            ;;
        cpu-debounce|cpu-consecutive)
            config_key="ALERT_CPU_CONSECUTIVE"
            name="CPU 防抖连续次数"
            unit=" 次"
            ;;
        net-debounce|net-consecutive)
            config_key="ALERT_NET_CONSECUTIVE"
            name="网络防抖连续次数"
            unit=" 次"
            ;;
        *)
            ops_log_err "未知指标名称: '${target}' (支持: cpu, mem, disk, rx, tx, cooldown)"
            return 1
            ;;
    esac

    if ops_config_set "${config_key}" "${val}"; then
        echo -e "${COLOR_GREEN}✔ 已成功设置 ${name} 告警阈值为 ${val}${unit} (${config_key}=${val})${COLOR_RESET}"
    fi
}

# ------------------------------------------------------------------------------
# 告警中心全局概览与状态卡片 (ops alert)
# ------------------------------------------------------------------------------
ops_alert_show_overview() {
    # 1. 采集当前即时指标 (0.5s 快速差分)
    local raw_metrics
    raw_metrics=$(ops_collect_metrics 0.5)
    local ts cpu_val mem_val disk_val rx_val tx_val
    IFS=$'\t' read -r ts cpu_val mem_val disk_val rx_val tx_val <<< "${raw_metrics}"

    local rx_mb tx_mb
    rx_mb=$(awk -v k="${rx_val:-0}" 'BEGIN { printf "%.2f", (k / 1024.0) }')
    tx_mb=$(awk -v k="${tx_val:-0}" 'BEGIN { printf "%.2f", (k / 1024.0) }')

    # 2. 加载状态机
    _ops_alert_load_state

    # 3. 加载阈值配置
    local cpu_thresh mem_thresh disk_thresh cpu_consecutive cooldown_min
    local net_rx_thresh net_tx_thresh net_consecutive
    cpu_thresh=$(ops_config_get "ALERT_CPU_THRESHOLD" "85")
    cpu_consecutive=$(ops_config_get "ALERT_CPU_CONSECUTIVE" "3")
    mem_thresh=$(ops_config_get "ALERT_MEM_THRESHOLD" "90")
    disk_thresh=$(ops_config_get "ALERT_DISK_THRESHOLD" "85")
    net_rx_thresh=$(ops_config_get "ALERT_NET_RX_THRESHOLD_MB" "50")
    net_tx_thresh=$(ops_config_get "ALERT_NET_TX_THRESHOLD_MB" "50")
    net_consecutive=$(ops_config_get "ALERT_NET_CONSECUTIVE" "3")
    cooldown_min=$(ops_config_get "ALERT_COOLDOWN_MINUTES" "30")

    # 4. 获取守护进程状态
    local daemon_info daemon_is_running daemon_detail daemon_badge daemon_status_text
    daemon_info=$(_ops_alert_get_daemon_status)
    daemon_is_running="${daemon_info%%|*}"
    daemon_detail="${daemon_info#*|}"

    if [[ "${daemon_is_running}" == "1" ]]; then
        daemon_badge="${COLOR_BG_GREEN}${COLOR_WHITE} 运行中 ${COLOR_RESET}"
        daemon_status_text="${COLOR_GREEN}🟢 正在运行${COLOR_RESET} (${daemon_detail})"
    else
        daemon_badge="${COLOR_BG_RED}${COLOR_WHITE} 未启动 ${COLOR_RESET}"
        daemon_status_text="${COLOR_RED}🔴 未启动${COLOR_RESET} (${daemon_detail}，可执行 ${COLOR_CYAN}ops alert start${COLOR_RESET} 启动)"
    fi

    local host
    host=$(_ops_get_hostname)

    # Webhook 通道状态
    local slack_url ding_url feishu_url wecom_url
    slack_url=$(ops_config_get "WEBHOOK_SLACK_URL" "")
    ding_url=$(ops_config_get "WEBHOOK_DINGTALK_URL" "")
    feishu_url=$(ops_config_get "WEBHOOK_FEISHU_URL" "")
    wecom_url=$(ops_config_get "WEBHOOK_WECOM_URL" "")

    _mask_url() {
        local u="$1"
        if [[ -z "${u}" ]]; then
            echo "${COLOR_DIM}未配置 (使用: ops alert webhook <渠道> <URL>)${COLOR_RESET}"
        else
            local len=${#u}
            if [[ $len -le 28 ]]; then
                echo "${COLOR_GREEN}已配置${COLOR_RESET} (${u})"
            else
                echo "${COLOR_GREEN}已配置${COLOR_RESET} (${u:0:22}...${u: -5})"
            fi
        fi
    }

    _format_alert_line() {
        local name_padded="$1"
        local cur="$2"
        local unit="$3"
        local thresh="$4"
        local deb="$5"
        local state_key="$6"

        local st="${OPS_ALERT_STATE[${state_key}_STATE]:-NORMAL}"
        local cnt="${OPS_ALERT_STATE[${state_key}_CONSECUTIVE_COUNT]:-0}"
        local last_time="${OPS_ALERT_STATE[${state_key}_LAST_ALERT_TIME]:-0}"

        local thresh_display=">= ${thresh}${unit}"
        if [[ "${thresh}" == "0" ]]; then
            thresh_display="已关闭 (0)"
        fi

        local deb_display="即时 (1次)"
        if [[ "${deb}" -gt 1 ]]; then
            deb_display="连续 ${deb} 次"
        fi

        local st_badge="${COLOR_GREEN}🟢 正常 (NORMAL)${COLOR_RESET}"
        local note="${COLOR_DIM}安全${COLOR_RESET}"

        if [[ "${thresh}" == "0" ]]; then
            st_badge="${COLOR_GRAY}⚪ 已禁用${COLOR_RESET}"
            note="${COLOR_DIM}未启用${COLOR_RESET}"
        elif [[ "${st}" == "COOLDOWN" ]]; then
            st_badge="${COLOR_RED}🔴 告警冷却 (COOLDOWN)${COLOR_RESET}"
            local elapsed=$(( $(date +%s) - last_time ))
            local rem=$(( (cooldown_min * 60) - elapsed ))
            if [[ "${rem}" -gt 0 ]]; then
                note="${COLOR_YELLOW}冷却还剩 $(( rem / 60 ))m$(( rem % 60 ))s${COLOR_RESET}"
            else
                note="${COLOR_RED}冷却结束将重发${COLOR_RESET}"
            fi
        elif [[ "${st}" == "SUSPECTED" ]]; then
            st_badge="${COLOR_YELLOW}🟡 怀疑中 (SUSPECTED)${COLOR_RESET}"
            note="${COLOR_YELLOW}已超限 ${cnt}/${deb} 次${COLOR_RESET}"
        fi

        local cur_str="${cur}${unit}"
        printf "│  %s   %-10s   %-13s   %-11s   %-27b   %b\n" \
            "${name_padded}" "${cur_str}" "${thresh_display}" "${deb_display}" "${st_badge}" "${note}"
    }

    cat <<EOF

${COLOR_BOLD}┌────────────────────────────────────────────────────────────────────────┐${COLOR_RESET}
${COLOR_BOLD}│  Ops-Monitor 告警中心与阈值状态               [${daemon_badge}${COLOR_BOLD}] │${COLOR_RESET}
${COLOR_BOLD}├────────────────────────────────────────────────────────────────────────┤${COLOR_RESET}
│  主机节点: ${COLOR_CYAN}${host}${COLOR_RESET}                     当前时间: $(date '+%Y-%m-%d %H:%M:%S')
│  服务状态: ${daemon_status_text}
│  静默冷却: ${cooldown_min} 分钟 (ALERT_COOLDOWN_MINUTES)
│
│${COLOR_BOLD}  指标名称       当前实时值   告警阈值        触发规则     当前状态                  说明${COLOR_RESET}
│  ──────────────────────────────────────────────────────────────────────
EOF
    _format_alert_line "CPU 使用率  " "${cpu_val}" "%" "${cpu_thresh}" "${cpu_consecutive}" "CPU"
    _format_alert_line "内存使用率  " "${mem_val}" "%" "${mem_thresh}" 1 "MEM"
    _format_alert_line "磁盘使用率  " "${disk_val}" "%" "${disk_thresh}" 1 "DISK"
    _format_alert_line "网络入站(RX)" "${rx_mb}" " MB/s" "${net_rx_thresh}" "${net_consecutive}" "NET_RX"
    _format_alert_line "网络出站(TX)" "${tx_mb}" " MB/s" "${net_tx_thresh}" "${net_consecutive}" "NET_TX"

    cat <<EOF
│
│${COLOR_BOLD}  --- 通知推送渠道 (Webhook) ---${COLOR_RESET}
│  [+] 钉钉 (DingTalk)  : $(_mask_url "${ding_url}")
│  [+] 飞书 (Feishu)    : $(_mask_url "${feishu_url}")
│  [+] 企业微信 (WeCom) : $(_mask_url "${wecom_url}")
│  [+] Slack            : $(_mask_url "${slack_url}")
${COLOR_BOLD}└────────────────────────────────────────────────────────────────────────┘${COLOR_RESET}

${COLOR_BOLD}💡 极简操作命令:${COLOR_RESET}
  • ${COLOR_CYAN}ops alert set <cpu|mem|disk|rx|tx|cooldown> <数值>${COLOR_RESET}  一键修改阈值 (例如: ops alert set cpu 90)
  • ${COLOR_CYAN}ops alert test${COLOR_RESET}                                      向已配置渠道发送测试告警
  • ${COLOR_CYAN}ops alert <start|stop|restart>${COLOR_RESET}                      一键启动 / 停止 / 重启后台监控服务
  • ${COLOR_CYAN}ops alert webhook <dingtalk|feishu|wecom|slack> <URL> [SECRET]${COLOR_RESET}
                                                          一键配置告警通知渠道

EOF
}

# ------------------------------------------------------------------------------
# 告警模块统一 CLI 路由分发 (ops alert [args...])
# ------------------------------------------------------------------------------
ops_alert_cli() {
    local sub="${1:-}"
    shift 2>/dev/null || true

    case "${sub}" in
        ""|status|list|show)
            ops_alert_show_overview
            ;;
        set)
            local target="${1:-}"
            local val="${2:-}"
            if [[ -z "${target}" || -z "${val}" ]]; then
                echo "用法: ops alert set <cpu|mem|disk|rx|tx|cooldown> <数值>"
                echo "示例: ops alert set cpu 90"
                return 1
            fi
            _ops_alert_set_metric "${target}" "${val}"
            ;;
        cpu|mem|disk|rx|tx|cooldown)
            local val="${1:-}"
            if [[ -z "${val}" ]]; then
                echo "用法: ops alert ${sub} <数值>"
                echo "示例: ops alert ${sub} 85"
                return 1
            fi
            _ops_alert_set_metric "${sub}" "${val}"
            ;;
        test|test-alert)
            ops_webhook_test_alert
            ;;
        start|stop|restart|enable|disable)
            if declare -f ops_manage_daemon >/dev/null 2>&1; then
                ops_manage_daemon "${sub}"
            else
                systemctl "${sub}" ops-daemon.service 2>/dev/null || true
            fi
            ;;
        webhook)
            local wtype="${1:-}"
            local wurl="${2:-}"
            local wsec="${3:-}"
            if [[ -z "${wtype}" || "${wtype}" == "-h" || "${wtype}" == "--help" || "${wtype}" == "help" ]]; then
                cat <<EOF

${COLOR_BOLD}=== Ops-Monitor Webhook 通知配置指南 ===${COLOR_RESET}

${COLOR_BOLD}用法:${COLOR_RESET}
  ops alert webhook <dingtalk|feishu|wecom|slack> <URL> [SECRET]

${COLOR_BOLD}各平台机器人配置示例 (复制即用):${COLOR_RESET}

  ${COLOR_CYAN}1. 飞书自定义机器人 (Feishu):${COLOR_RESET}
     群设置 -> 机器人 -> 添加机器人 -> 自定义机器人 -> 复制 Webhook 地址
     ${COLOR_BOLD}ops alert webhook feishu "https://open.feishu.cn/open-apis/bot/v2/hook/xxxxxx"${COLOR_RESET}

  ${COLOR_CYAN}2. 钉钉群机器人 (DingTalk):${COLOR_RESET}
     群设置 -> 智能群助手 -> 添加机器人 -> 自定义 (安全设置选"加签"或"IP")
     • 带加签秘钥 (推荐):
       ${COLOR_BOLD}ops alert webhook dingtalk "https://oapi.dingtalk.com/robot/send?access_token=xxxxxx" "SECxxxxxx"${COLOR_RESET}
     • 普通 Webhook (无加签):
       ${COLOR_BOLD}ops alert webhook dingtalk "https://oapi.dingtalk.com/robot/send?access_token=xxxxxx"${COLOR_RESET}

  ${COLOR_CYAN}3. 企业微信群机器人 (WeCom):${COLOR_RESET}
     群设置 -> 添加群机器人 -> 复制 Webhook 地址
     ${COLOR_BOLD}ops alert webhook wecom "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=xxxxxx"${COLOR_RESET}

  ${COLOR_CYAN}4. Slack 机器人 (Incoming Webhooks):${COLOR_RESET}
     Slack App -> Incoming WebHooks -> 复制 Webhook URL
     ${COLOR_BOLD}ops alert webhook slack "https://hooks.slack.com/services/T00/B00/XXXX"${COLOR_RESET}

💡 配置完成后，执行 ${COLOR_CYAN}ops alert test${COLOR_RESET} 可立即发送测试卡片验证连通性。

EOF
                return 0
            fi
            if [[ -z "${wurl}" ]]; then
                echo "用法: ops alert webhook <dingtalk|feishu|wecom|slack> <URL> [SECRET]"
                echo "示例: ops alert webhook feishu https://open.feishu.cn/open-apis/bot/v2/hook/xxxx"
                return 1
            fi
            case "${wtype}" in
                ding|dingtalk)
                    ops_config_set "WEBHOOK_DINGTALK_URL" "${wurl}"
                    [[ -n "${wsec}" ]] && ops_config_set "WEBHOOK_DINGTALK_SECRET" "${wsec}"
                    ops_log_info "已成功配置钉钉 Webhook"
                    ;;
                feishu)
                    ops_config_set "WEBHOOK_FEISHU_URL" "${wurl}"
                    ops_log_info "已成功配置飞书 Webhook"
                    ;;
                wecom|weixin|wechat)
                    ops_config_set "WEBHOOK_WECOM_URL" "${wurl}"
                    ops_log_info "已成功配置企业微信 Webhook"
                    ;;
                slack)
                    ops_config_set "WEBHOOK_SLACK_URL" "${wurl}"
                    ops_log_info "已成功配置 Slack Webhook"
                    ;;
                *)
                    ops_log_err "未知 Webhook 类型 '${wtype}' (支持: dingtalk, feishu, wecom, slack)"
                    return 1
                    ;;
            esac
            ;;
        reset|default)
            ops_config_set "ALERT_CPU_THRESHOLD" "85"
            ops_config_set "ALERT_CPU_CONSECUTIVE" "3"
            ops_config_set "ALERT_MEM_THRESHOLD" "90"
            ops_config_set "ALERT_DISK_THRESHOLD" "85"
            ops_config_set "ALERT_NET_RX_THRESHOLD_MB" "50"
            ops_config_set "ALERT_NET_TX_THRESHOLD_MB" "50"
            ops_config_set "ALERT_NET_CONSECUTIVE" "3"
            ops_config_set "ALERT_COOLDOWN_MINUTES" "30"
            echo -e "${COLOR_GREEN}✔ 已将所有告警阈值一键恢复为出厂默认值 (CPU 85%, 内存 90%, 磁盘 85%, 网络 50MB/s, 冷却 30m)${COLOR_RESET}"
            ;;
        help|-h|--help)
            cat <<EOF

${COLOR_BOLD}================================================================================${COLOR_RESET}
  ${COLOR_BOLD}Ops-Monitor 告警中心与 Webhook 配置说明 (ops alert -h)${COLOR_RESET}
${COLOR_BOLD}================================================================================${COLOR_RESET}

${COLOR_BOLD}【常用命令速查】${COLOR_RESET}
  ${COLOR_CYAN}ops alert${COLOR_RESET}                              查看告警阈值、实时数值、状态机与服务状态
  ${COLOR_CYAN}ops alert set <指标> <数值>${COLOR_RESET}            修改告警阈值 (例如: ops alert set cpu 90)
  ${COLOR_CYAN}ops alert <cpu|mem|disk|rx|tx> <数值>${COLOR_RESET}  快捷修改阈值 (例如: ops alert mem 80)
  ${COLOR_CYAN}ops alert reset${COLOR_RESET}                        一键将所有阈值恢复为系统出厂默认值
  ${COLOR_CYAN}ops alert test${COLOR_RESET}                         向已配置的 Webhook 发送一条模拟告警卡片
  ${COLOR_CYAN}ops alert <start|stop|restart>${COLOR_RESET}         一键启动 / 停止 / 重启后台监控服务
  ${COLOR_CYAN}ops alert <enable|disable>${COLOR_RESET}             开启或彻底关闭后台服务开机自启

${COLOR_BOLD}【常用 Webhook 机器人添加示例 (复制即用)】${COLOR_RESET}

  ${COLOR_CYAN}1. 飞书自定义机器人 (Feishu):${COLOR_RESET}
     • 获取方法: 群设置 -> 机器人 -> 添加机器人 -> 自定义机器人 -> 复制 Webhook 地址
     • 快速设置:
       ${COLOR_BOLD}ops alert webhook feishu "https://open.feishu.cn/open-apis/bot/v2/hook/xxxxxx"${COLOR_RESET}

  ${COLOR_CYAN}2. 钉钉群机器人 (DingTalk):${COLOR_RESET}
     • 获取方法: 群设置 -> 智能群助手 -> 添加机器人 -> 自定义
     • 带加签安全密钥 (推荐):
       ${COLOR_BOLD}ops alert webhook dingtalk "https://oapi.dingtalk.com/robot/send?access_token=xxxxxx" "SECxxxxxx"${COLOR_RESET}
     • 普通 Webhook (无加签):
       ${COLOR_BOLD}ops alert webhook dingtalk "https://oapi.dingtalk.com/robot/send?access_token=xxxxxx"${COLOR_RESET}

  ${COLOR_CYAN}3. 企业微信群机器人 (WeCom):${COLOR_RESET}
     • 获取方法: 群设置 -> 添加群机器人 -> 复制 Webhook 地址
     • 快速设置:
       ${COLOR_BOLD}ops alert webhook wecom "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=xxxxxx"${COLOR_RESET}

  ${COLOR_CYAN}4. Slack 机器人 (Incoming Webhooks):${COLOR_RESET}
     • 获取方法: Slack App 管理 -> Incoming WebHooks -> 添加并复制 URL
     • 快速设置:
       ${COLOR_BOLD}ops alert webhook slack "https://hooks.slack.com/services/T00/B00/XXXX"${COLOR_RESET}

${COLOR_BOLD}【监控指标参数说明】${COLOR_RESET}
  • ${COLOR_BOLD}cpu${COLOR_RESET}      : CPU 告警阈值 (%)，默认 85% (连续 3 次超限防抖)
  • ${COLOR_BOLD}mem${COLOR_RESET}      : 内存告警阈值 (%)，默认 90% (即时触发，防 OOM 宕机)
  • ${COLOR_BOLD}disk${COLOR_RESET}     : 磁盘主分区告警阈值 (%)，默认 85% (即时触发)
  • ${COLOR_BOLD}rx / tx${COLOR_RESET}  : 网络入站 / 出站吞吐量阈值 (MB/s)，默认 50 MB/s (设为 0 关闭)
  • ${COLOR_BOLD}cooldown${COLOR_RESET} : 告警触发后的静默冷却周期 (分钟)，默认 30 分钟 (防止刷屏骚扰)
${COLOR_BOLD}================================================================================${COLOR_RESET}

EOF
            ;;
        *)
            ops_log_err "未知 alert 子命令: '${sub}'，执行 'ops alert help' 查看帮助"
            return 1
            ;;
    esac
}

