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
