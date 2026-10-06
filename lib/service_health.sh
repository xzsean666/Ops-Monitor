#!/usr/bin/env bash
# ==============================================================================
# Ops-Monitor 业务服务健康探测与自愈引擎 (lib/service_health.sh)
# 针对 HTTP 端点执行定时心跳探测，具备防抖 (Debounce) 与静默冷却 (Cooldown)
# 支持探测异常时自动 Webhook 告警并触发自愈重启动作 (如 docker restart)
# ==============================================================================

_SERVICE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${_SERVICE_LIB_DIR}/common.sh"
# shellcheck source=config_mgr.sh
source "${_SERVICE_LIB_DIR}/config_mgr.sh"
# shellcheck source=webhook.sh
source "${_SERVICE_LIB_DIR}/webhook.sh"
# shellcheck source=render.sh
source "${_SERVICE_LIB_DIR}/render.sh"
unset _SERVICE_LIB_DIR

OPS_SERVICE_STATE_FILE="${OPS_SERVICE_STATE_FILE:-${OPS_STATE_DATA_DIR}/service_health.state}"

declare -g -A OPS_SERVICE_STATE 2>/dev/null || true

_ops_service_sanitize_key() {
    local raw="$1"
    local clean
    clean=$(echo "${raw}" | tr -cd 'A-Za-z0-9_')
    [[ -z "${clean}" ]] && clean="SRV_UNKNOWN"
    echo "${clean}"
}

_ops_service_load_state() {
    OPS_SERVICE_STATE=()
    if [[ -f "${OPS_SERVICE_STATE_FILE}" ]]; then
        while IFS= read -r line || [[ -n "${line}" ]]; do
            [[ -z "${line}" || "${line}" =~ ^# ]] && continue
            if [[ "${line}" =~ ^([A-Za-z0-9_]+)=(.*)$ ]]; then
                OPS_SERVICE_STATE["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
            fi
        done < "${OPS_SERVICE_STATE_FILE}"
    fi
}

_ops_service_save_state() {
    ops_ensure_dirs || return "${OPS_EXIT_PERM_ERR}"

    local tmp_file="${OPS_SERVICE_STATE_FILE}.tmp.$$"
    {
        echo "# Ops-Monitor 服务健康状态缓存 ($(date '+%Y-%m-%d %H:%M:%S'))"
        for k in "${!OPS_SERVICE_STATE[@]}"; do
            echo "${k}=${OPS_SERVICE_STATE[${k}]}"
        done
    } > "${tmp_file}"

    mv -f "${tmp_file}" "${OPS_SERVICE_STATE_FILE}"
    ops_secure_file "${OPS_SERVICE_STATE_FILE}"
}

# ------------------------------------------------------------------------------
# 单服务健康探测与自愈评估
# ------------------------------------------------------------------------------
ops_service_health_check_one() {
    local name="$1"
    local probe_url="$2"
    local restart_cmd="${3:-}"
    local consecutive_req="${4:-2}"
    local cooldown_min="${5:-10}"
    local timeout_sec="${6:-5}"

    [[ -z "${name}" || -z "${probe_url}" ]] && return 0

    _ops_service_load_state

    local s_key
    s_key=$(_ops_service_sanitize_key "${name}")

    local state_key="${s_key}_STATE"
    local count_key="${s_key}_FAIL_COUNT"
    local last_alert_key="${s_key}_LAST_ALERT_TIME"
    local last_code_key="${s_key}_LAST_HTTP_CODE"
    local last_check_key="${s_key}_LAST_CHECK_TIME"

    local current_state="${OPS_SERVICE_STATE[${state_key}]:-NORMAL}"
    local fail_count="${OPS_SERVICE_STATE[${count_key}]:-0}"
    local last_alert_time="${OPS_SERVICE_STATE[${last_alert_key}]:-0}"
    local now_ts
    now_ts="$(date +%s)"

    # 执行 HTTP GET 探测
    local http_code
    http_code=$(curl --connect-timeout "${timeout_sec}" --max-time "${timeout_sec}" -s -o /dev/null -w "%{http_code}" "${probe_url}" 2>/dev/null || echo "000")

    OPS_SERVICE_STATE["${last_code_key}"]="${http_code}"
    OPS_SERVICE_STATE["${last_check_key}"]="${now_ts}"

    if [[ "${http_code}" =~ ^(200|204|301|302|304|307|308)$ ]]; then
        # 探测成功 (服务正常)
        if [[ "${current_state}" == "COOLDOWN" || "${current_state}" == "ALERTED" ]]; then
            ops_log_info "[服务自愈/恢复] ${name} (${probe_url}) 响应码 ${http_code}，服务已恢复正常"
            ops_webhook_broadcast_service "${name}" "${probe_url}" "${http_code}" "服务探活已恢复正常 (HTTP ${http_code})" 1 "${restart_cmd}"
        fi

        OPS_SERVICE_STATE["${state_key}"]="NORMAL"
        OPS_SERVICE_STATE["${count_key}"]="0"
    else
        # 探测失败 (HTTP 异常或连接中断)
        local err_detail="HTTP 状态码异常 (${http_code})"
        if [[ "${http_code}" == "000" ]]; then
            err_detail="连接超时或端口未监听 (Connection Refused / Timeout)"
        fi

        # 检查关联的 Docker 容器退出/状态 (若配置了 docker restart/start 命令)
        local container_name=""
        if [[ "${restart_cmd}" =~ docker[[:space:]]+(restart|start)[[:space:]]+([A-Za-z0-9_-]+) ]]; then
            container_name="${BASH_REMATCH[2]}"
        fi

        if [[ -n "${container_name}" ]] && command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
            local c_inspect
            c_inspect=$(docker inspect -f '{{.State.Status}}|{{.State.ExitCode}}|{{.State.OOMKilled}}' "${container_name}" 2>/dev/null || echo "")
            if [[ -n "${c_inspect}" ]]; then
                local c_status="" c_exit_code="" c_oom=""
                IFS='|' read -r c_status c_exit_code c_oom <<< "${c_inspect}"
                if [[ "${c_status}" == "exited" || "${c_status}" == "dead" || "${c_status}" == "restarting" ]]; then
                    if [[ "${c_oom}" == "true" ]]; then
                        err_detail="容器内存耗尽崩溃终止 (OOMKilled, 退出码: ${c_exit_code})"
                    elif [[ "${c_status}" == "restarting" ]]; then
                        err_detail="容器处于崩溃重启循环中 (Docker: restarting, 退出码: ${c_exit_code})"
                    else
                        err_detail="容器主进程已异常退出终止 (Docker: exited, 退出码: ${c_exit_code})"
                    fi
                    # 容器已明确异常终止，立即告警与自愈，无需等待防抖
                    consecutive_req=1
                fi
            fi
        fi

        if [[ "${current_state}" == "COOLDOWN" ]]; then
            local cooldown_sec=$(( cooldown_min * 60 ))
            local elapsed=$(( now_ts - last_alert_time ))

            if [[ "${elapsed}" -ge "${cooldown_sec}" ]]; then
                ops_log_warn "[服务告警触发] ${name} 持续异常 (${err_detail})，冷却期结束再次告警与自愈"
                ops_webhook_broadcast_service "${name}" "${probe_url}" "${http_code}" "服务持续异常 (${err_detail})，冷却期结束再次触发自愈" 0 "${restart_cmd}"

                if [[ -n "${restart_cmd}" ]]; then
                    ops_log_info "[服务自愈] 正在执行自愈命令: ${restart_cmd}"
                    eval "${restart_cmd}" >/dev/null 2>&1 || ops_log_warn "[服务自愈] 自愈命令返回非 0 状态码"
                fi

                OPS_SERVICE_STATE["${state_key}"]="COOLDOWN"
                OPS_SERVICE_STATE["${last_alert_key}"]="${now_ts}"
                OPS_SERVICE_STATE["${count_key}"]="${consecutive_req}"
            else
                ops_log_debug "${name} 处于自愈冷却期中 (${elapsed}s/${cooldown_sec}s)，抑制重复报警"
                OPS_SERVICE_STATE["${state_key}"]="COOLDOWN"
            fi
        elif [[ "${current_state}" == "NORMAL" ]]; then
            if [[ "${consecutive_req}" -le 1 ]]; then
                ops_log_warn "[服务告警触发] ${name} 探活失败 (${err_detail})，立即告警并自愈"
                ops_webhook_broadcast_service "${name}" "${probe_url}" "${http_code}" "服务探活异常 (${err_detail})，触发告警与自愈" 0 "${restart_cmd}"

                if [[ -n "${restart_cmd}" ]]; then
                    ops_log_info "[服务自愈] 正在执行自愈命令: ${restart_cmd}"
                    eval "${restart_cmd}" >/dev/null 2>&1 || ops_log_warn "[服务自愈] 自愈命令返回非 0 状态码"
                fi

                OPS_SERVICE_STATE["${state_key}"]="COOLDOWN"
                OPS_SERVICE_STATE["${count_key}"]="1"
                OPS_SERVICE_STATE["${last_alert_key}"]="${now_ts}"
            else
                ops_log_info "[服务防抖判定] ${name} 首次探活失败 (${err_detail})，进入怀疑状态 (1/${consecutive_req})"
                OPS_SERVICE_STATE["${state_key}"]="SUSPECTED"
                OPS_SERVICE_STATE["${count_key}"]="1"
            fi
        elif [[ "${current_state}" == "SUSPECTED" ]]; then
            fail_count=$(( fail_count + 1 ))
            if [[ "${fail_count}" -ge "${consecutive_req}" ]]; then
                ops_log_warn "[服务告警触发] ${name} 连续探活失败达 ${fail_count} 次 (${err_detail})，触发告警与自愈"
                ops_webhook_broadcast_service "${name}" "${probe_url}" "${http_code}" "连续 ${fail_count} 次探活失败 (${err_detail})，正在执行自愈" 0 "${restart_cmd}"

                if [[ -n "${restart_cmd}" ]]; then
                    ops_log_info "[服务自愈] 正在执行自愈命令: ${restart_cmd}"
                    eval "${restart_cmd}" >/dev/null 2>&1 || ops_log_warn "[服务自愈] 自愈命令返回非 0 状态码"
                fi

                OPS_SERVICE_STATE["${state_key}"]="COOLDOWN"
                OPS_SERVICE_STATE["${count_key}"]="${fail_count}"
                OPS_SERVICE_STATE["${last_alert_key}"]="${now_ts}"
            else
                ops_log_info "[服务防抖判定] ${name} 持续探活失败 (${err_detail})，怀疑中 (${fail_count}/${consecutive_req})"
                OPS_SERVICE_STATE["${state_key}"]="SUSPECTED"
                OPS_SERVICE_STATE["${count_key}"]="${fail_count}"
            fi
        fi
    fi

    _ops_service_save_state
}

# ------------------------------------------------------------------------------
# 评估所有已配置的服务健康探测项
# ------------------------------------------------------------------------------
ops_service_health_evaluate_all() {
    local raw_checks
    raw_checks=$(ops_config_get "SERVICE_HEALTH_CHECKS" "")
    [[ -z "${raw_checks}" ]] && return 0

    local default_consecutive default_cooldown default_timeout
    default_consecutive=$(ops_config_get "SERVICE_HEALTH_CONSECUTIVE" "2")
    default_cooldown=$(ops_config_get "SERVICE_HEALTH_COOLDOWN_MINUTES" "10")
    default_timeout=$(ops_config_get "SERVICE_HEALTH_TIMEOUT_SECONDS" "5")

    _ops_service_load_state

    # 支持换行符与分号作为条目分隔符
    local sanitized_checks
    sanitized_checks=$(echo "${raw_checks}" | tr ';' '\n')

    while IFS= read -r item || [[ -n "${item}" ]]; do
        item=$(echo "${item}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        [[ -z "${item}" || "${item}" =~ ^# ]] && continue

        # 格式: 服务名|探活URL|重启命令|连续失败次数|冷却分钟|超时秒
        IFS='|' read -r s_name s_url s_cmd s_req s_cd s_to <<< "${item}"

        [[ -z "${s_name}" || -z "${s_url}" ]] && continue

        local req="${s_req:-$default_consecutive}"
        local cd="${s_cd:-$default_cooldown}"
        local to="${s_to:-$default_timeout}"

        ops_service_health_check_one "${s_name}" "${s_url}" "${s_cmd}" "${req}" "${cd}" "${to}"
    done <<< "${sanitized_checks}"

    # 容器内存指标监测与防 OOM 预警
    ops_service_container_memory_evaluate

    _ops_service_save_state
}

# ------------------------------------------------------------------------------
# 容器内存指标监控与告警 (防 V8 堆内存 / 容器 OOM 盲区)
# ------------------------------------------------------------------------------
ops_service_container_memory_evaluate() {
    local threshold
    threshold=$(ops_config_get "ALERT_CONTAINER_MEM_THRESHOLD" "80")
    [[ -z "${threshold}" || "${threshold}" -le 0 ]] && return 0

    command -v docker >/dev/null 2>&1 || return 0
    docker info >/dev/null 2>&1 || return 0

    local stats_raw
    stats_raw=$(docker stats --no-stream --format "{{.Name}}\t{{.MemPerc}}\t{{.MemUsage}}" 2>/dev/null || echo "")
    [[ -z "${stats_raw}" ]] && return 0

    while IFS=$'\t' read -r c_name c_mem_perc c_mem_usage || [[ -n "${c_name}" ]]; do
        [[ -z "${c_name}" || -z "${c_mem_perc}" ]] && continue

        local clean_perc
        clean_perc=$(echo "${c_mem_perc}" | tr -cd '0-9.')
        [[ -z "${clean_perc}" ]] && continue

        local is_high
        is_high=$(awk -v val="${clean_perc}" -v th="${threshold}" 'BEGIN { print (val >= th) ? 1 : 0 }')

        local s_key
        s_key="CMEM_$(_ops_service_sanitize_key "${c_name}")"
        local state_key="${s_key}_STATE"
        local last_alert_key="${s_key}_LAST_ALERT"
        local cur_state="${OPS_SERVICE_STATE[${state_key}]:-NORMAL}"
        local last_alert_ts="${OPS_SERVICE_STATE[${last_alert_key}]:-0}"
        local now_ts
        now_ts="$(date +%s)"

        if [[ "${is_high}" -eq 1 ]]; then
            if [[ "${cur_state}" != "ALERTED" || $(( now_ts - last_alert_ts )) -ge 1800 ]]; then
                ops_log_warn "[容器内存告警] 容器 ${c_name} 内存占用达 ${c_mem_perc} (>= 阈值 ${threshold}%)，当前用量: ${c_mem_usage}"
                ops_webhook_broadcast_service "${c_name}" "Docker Container Memory" "${c_mem_perc}" "容器内存占比达 ${c_mem_perc} (当前用量: ${c_mem_usage}, 预警阈值: ${threshold}%)，存在 OOM 崩溃风险，请及时排查！" 0 ""
                OPS_SERVICE_STATE["${state_key}"]="ALERTED"
                OPS_SERVICE_STATE["${last_alert_key}"]="${now_ts}"
            fi
        else
            if [[ "${cur_state}" == "ALERTED" ]]; then
                ops_log_info "[容器内存恢复] 容器 ${c_name} 内存已回落至安全水位 (${c_mem_perc} < ${threshold}%)"
                ops_webhook_broadcast_service "${c_name}" "Docker Container Memory" "${c_mem_perc}" "容器内存已恢复至安全水位 (${c_mem_perc} < ${threshold}%, 当前用量: ${c_mem_usage})" 1 ""
                OPS_SERVICE_STATE["${state_key}"]="NORMAL"
            fi
        fi
    done <<< "${stats_raw}"
}

# ------------------------------------------------------------------------------
# 查询所有服务健康的整体状态 (NORMAL / WARN / CRITICAL)
# ------------------------------------------------------------------------------
ops_service_health_get_overall_status() {
    _ops_service_load_state

    local overall="NORMAL"
    for k in "${!OPS_SERVICE_STATE[@]}"; do
        if [[ "${k}" == *"_STATE" ]]; then
            local val="${OPS_SERVICE_STATE[${k}]}"
            if [[ "${val}" == "COOLDOWN" || "${val}" == "ALERTED" ]]; then
                echo "CRITICAL"
                return 0
            elif [[ "${val}" == "SUSPECTED" ]]; then
                overall="WARN"
            fi
        fi
    done

    echo "${overall}"
}

# ------------------------------------------------------------------------------
# CLI 查看与即时健康探测输出 (ops health / ops service)
# ------------------------------------------------------------------------------
ops_service_health_cli() {
    local raw_checks
    raw_checks=$(ops_config_get "SERVICE_HEALTH_CHECKS" "")

    echo -e "${COLOR_BOLD}================================================================================${COLOR_RESET}"
    echo -e "${COLOR_BOLD}        Ops-Monitor 业务服务健康探测与自愈监控 (Service Health)                 ${COLOR_RESET}"
    echo -e "${COLOR_BOLD}================================================================================${COLOR_RESET}"

    if [[ -z "${raw_checks}" ]]; then
        echo -e "  ${COLOR_YELLOW}💡 提示: 暂未配置任何业务服务健康探测规则。${COLOR_RESET}"
        echo ""
        echo -e "  如需启用服务健康探活与自愈，请在 /etc/ops-monitor/ops.conf 中配置:"
        echo -e "  ${COLOR_CYAN}SERVICE_HEALTH_CHECKS=\"AstarFi-Backend|http://127.0.0.1:10101/health|docker restart astar-fi-backend-v2-stag\"${COLOR_RESET}"
        echo -e "${COLOR_BOLD}================================================================================${COLOR_RESET}"
        return 0
    fi

    local timeout_sec
    timeout_sec=$(ops_config_get "SERVICE_HEALTH_TIMEOUT_SECONDS" "5")

    _ops_service_load_state

    printf "  %-20s %-32s %-10s %-12s\n" "服务名称" "探测地址" "HTTP状态" "运行状况"
    echo -e "  ------------------------------------------------------------------------------"

    local sanitized_checks
    sanitized_checks=$(echo "${raw_checks}" | tr ';' '\n')

    while IFS= read -r item || [[ -n "${item}" ]]; do
        item=$(echo "${item}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        [[ -z "${item}" || "${item}" =~ ^# ]] && continue

        IFS='|' read -r s_name s_url s_cmd s_req s_cd s_to <<< "${item}"
        [[ -z "${s_name}" || -z "${s_url}" ]] && continue

        local to="${s_to:-$timeout_sec}"
        local http_code
        http_code=$(curl --connect-timeout "${to}" --max-time "${to}" -s -o /dev/null -w "%{http_code}" "${s_url}" 2>/dev/null || echo "000")

        local status_label
        if [[ "${http_code}" =~ ^(200|204|301|302|304|307|308)$ ]]; then
            status_label="${COLOR_GREEN}● 正常 (UP)${COLOR_RESET}"
        else
            status_label="${COLOR_RED}✖ 异常 (DOWN)${COLOR_RESET}"
        fi

        local display_url="${s_url}"
        if [[ "${#display_url}" -gt 30 ]]; then
            display_url="${display_url:0:27}..."
        fi

        printf "  %-20s %-32s %-10s %-12b\n" "${s_name}" "${display_url}" "${http_code}" "${status_label}"
        if [[ -n "${s_cmd}" ]]; then
            echo -e "    ${COLOR_DIM}↳ 自愈动作: ${s_cmd}${COLOR_RESET}"
        fi
    done <<< "${sanitized_checks}"

    echo -e "${COLOR_BOLD}================================================================================${COLOR_RESET}"
}
