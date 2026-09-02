#!/usr/bin/env bash
# ==============================================================================
# Ops-Monitor Docker 容器实时资源监控引擎 (lib/docker.sh)
# 实时展示所有 Docker 容器资源占用 (CPU、内存、网络I/O、磁盘I/O、PIDs、状态)
# 零外部依赖、非侵入式探测、未安装友好降级、支持快照与 Live TUI 动态看板
# ==============================================================================

_DOCKER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${_DOCKER_LIB_DIR}/common.sh"
# shellcheck source=render.sh
source "${_DOCKER_LIB_DIR}/render.sh"
unset _DOCKER_LIB_DIR

# ------------------------------------------------------------------------------
# 1. Docker 环境嗅探与权限自适应探测
# 返回码: 0 - 正常可用, 1 - 未安装 Docker, 2 - Daemon 未启动或无访问权限
# ------------------------------------------------------------------------------
_ops_docker_get_cmd() {
    # 支持环境变量显式覆盖/Mock 测试
    if [[ -n "${OPS_DOCKER_CMD:-}" ]]; then
        echo "${OPS_DOCKER_CMD}"
        return 0
    fi

    if [[ "${OPS_DOCKER_MOCK:-}" == "not_installed" ]]; then
        return 1
    elif [[ "${OPS_DOCKER_MOCK:-}" == "permission_denied" || "${OPS_DOCKER_MOCK:-}" == "daemon_stopped" ]]; then
        return 2
    fi

    if ! command -v docker >/dev/null 2>&1; then
        return 1
    fi

    if docker info >/dev/null 2>&1; then
        echo "docker"
        return 0
    elif command -v sudo >/dev/null 2>&1 && sudo -n docker info >/dev/null 2>&1; then
        echo "sudo -n docker"
        return 0
    else
        return 2
    fi
}

# ------------------------------------------------------------------------------
# 2. Docker 环境状态诊断与友好提示
# ------------------------------------------------------------------------------
ops_docker_check_environment() {
    local d_cmd
    d_cmd=$(_ops_docker_get_cmd)
    local ret=$?

    if [[ "${ret}" -eq 1 ]]; then
        echo -e "${COLOR_BOLD}================================================================================${COLOR_RESET}"
        echo -e "${COLOR_BOLD}        Ops-Monitor Docker 容器实时资源监控 (Docker Stats)                      ${COLOR_RESET}"
        echo -e "${COLOR_BOLD}================================================================================${COLOR_RESET}"
        echo -e "  ${COLOR_YELLOW}💡 提示: 当前系统未检测到 Docker 环境 (未安装 Docker)。${COLOR_RESET}"
        echo ""
        echo -e "  如需使用容器监控功能，请先安装 Docker:"
        echo -e "    • Ubuntu/Debian: ${COLOR_CYAN}sudo apt update && sudo apt install -y docker.io${COLOR_RESET}"
        echo -e "    • 官方一键脚本:   ${COLOR_CYAN}curl -fsSL https://get.docker.com | bash${COLOR_RESET}"
        echo -e "${COLOR_BOLD}================================================================================${COLOR_RESET}"
        return 1
    elif [[ "${ret}" -eq 2 ]]; then
        echo -e "${COLOR_BOLD}================================================================================${COLOR_RESET}"
        echo -e "${COLOR_BOLD}        Ops-Monitor Docker 容器实时资源监控 (Docker Stats)                      ${COLOR_RESET}"
        echo -e "${COLOR_BOLD}================================================================================${COLOR_RESET}"
        echo -e "  ${COLOR_RED}⚠️  Docker 已安装，但无法连接到 Docker 守护进程 (Daemon)。${COLOR_RESET}"
        echo ""
        echo -e "  ${COLOR_BOLD}可能原因与解决方法:${COLOR_RESET}"
        echo -e "    1. Docker 服务未启动:"
        echo -e "       ${COLOR_CYAN}sudo systemctl start docker${COLOR_RESET}"
        echo -e "    2. 当前用户无权访问 Docker Socket (/var/run/docker.sock):"
        echo -e "       ${COLOR_CYAN}sudo usermod -aG docker \$USER${COLOR_RESET} (重新登录生效) 或使用 sudo 运行"
        echo -e "${COLOR_BOLD}================================================================================${COLOR_RESET}"
        return 2
    fi

    return 0
}

# ------------------------------------------------------------------------------
# 3. 实时采集并解析所有容器状态与资源
# ------------------------------------------------------------------------------
ops_docker_get_raw_stats() {
    local d_cmd
    d_cmd=$(_ops_docker_get_cmd) || return $?

    # 采集格式: ID \t Name \t CPUPerc \t MemUsage \t MemPerc \t NetIO \t BlockIO \t PIDs
    # shellcheck disable=SC2086
    ${d_cmd} stats --no-stream --format "{{.ID}}\t{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}\t{{.PIDs}}" 2>/dev/null
}

ops_docker_get_ps_info() {
    local d_cmd
    d_cmd=$(_ops_docker_get_cmd) || return $?

    # 采集格式: ID \t Name \t Status \t Image
    # shellcheck disable=SC2086
    ${d_cmd} ps -a --format "{{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Image}}" 2>/dev/null
}

# ------------------------------------------------------------------------------
# 4. 渲染 Docker 实时监控概览卡片 (Snapshot Card)
# ------------------------------------------------------------------------------
ops_docker_show_overview() {
    local d_cmd
    d_cmd=$(_ops_docker_get_cmd)
    local ret=$?

    if [[ "${ret}" -ne 0 ]]; then
        ops_docker_check_environment
        return "${ret}"
    fi

    local host
    host=$(_ops_get_hostname)
    local cur_time
    cur_time=$(date '+%Y-%m-%d %H:%M:%S')

    # 获取全量容器列表与状态
    local ps_data
    ps_data=$(ops_docker_get_ps_info)
    local total_containers=0
    local running_containers=0
    local stopped_containers=0

    # 关联数组映射状态
    local -A container_status_map
    local -A container_image_map

    if [[ -n "${ps_data}" ]]; then
        while IFS=$'\t' read -r cid cname cstatus cimage || [[ -n "${cid}" ]]; do
            [[ -z "${cid}" ]] && continue
            total_containers=$(( total_containers + 1 ))
            if [[ "${cstatus}" == Up* ]]; then
                running_containers=$(( running_containers + 1 ))
            else
                stopped_containers=$(( stopped_containers + 1 ))
            fi
            container_status_map["${cname}"]="${cstatus}"
            container_status_map["${cid}"]="${cstatus}"
            container_image_map["${cname}"]="${cimage}"
            container_image_map["${cid}"]="${cimage}"
        done <<< "${ps_data}"
    fi

    # 获取实时资源统计
    local stats_data
    stats_data=$(ops_docker_get_raw_stats)

    # 容器为空时的友好提示
    if [[ "${total_containers}" -eq 0 ]]; then
        cat <<EOF
${COLOR_BOLD}================================================================================${COLOR_RESET}
${COLOR_BOLD}        Ops-Monitor Docker 容器实时资源监控 (Docker Stats)                      ${COLOR_RESET}
${COLOR_BOLD}================================================================================${COLOR_RESET}
  ${COLOR_BOLD}主机节点:${COLOR_RESET} ${COLOR_CYAN}${host}${COLOR_RESET}          ${COLOR_BOLD}采样时间:${COLOR_RESET} ${cur_time}
  ${COLOR_BOLD}容器概况:${COLOR_RESET} ${COLOR_GREEN}0 运行中${COLOR_RESET} / 共 0 个容器
--------------------------------------------------------------------------------
  ${COLOR_DIM}Docker 守护服务正常运行中，当前没有创建任何容器。${COLOR_RESET}
${COLOR_BOLD}================================================================================${COLOR_RESET}
EOF
        return 0
    fi

    if [[ "${running_containers}" -eq 0 ]]; then
        cat <<EOF
${COLOR_BOLD}================================================================================${COLOR_RESET}
${COLOR_BOLD}        Ops-Monitor Docker 容器实时资源监控 (Docker Stats)                      ${COLOR_RESET}
${COLOR_BOLD}================================================================================${COLOR_RESET}
  ${COLOR_BOLD}主机节点:${COLOR_RESET} ${COLOR_CYAN}${host}${COLOR_RESET}          ${COLOR_BOLD}采样时间:${COLOR_RESET} ${cur_time}
  ${COLOR_BOLD}容器概况:${COLOR_RESET} ${COLOR_YELLOW}0 运行中${COLOR_RESET} / ${COLOR_RED}${stopped_containers} 已停止${COLOR_RESET} / 共 ${total_containers} 个容器
--------------------------------------------------------------------------------
  ${COLOR_DIM}当前所有 Docker 容器均处于停止 (Exited/Stopped) 状态，无实时资源消耗。${COLOR_RESET}
${COLOR_BOLD}================================================================================${COLOR_RESET}
EOF
        return 0
    fi

    # 汇总计算 CPU 与 活跃容器数
    local total_cpu_pct="0.0"
    local active_count=0

    if [[ -n "${stats_data}" ]]; then
        total_cpu_pct=$(echo "${stats_data}" | awk -F'\t' '{
            gsub(/%/, "", $3);
            sum += $3;
        } END { printf "%.2f", sum }')
        active_count=$(echo "${stats_data}" | grep -c "^" || true)
    fi

    cat <<EOF
${COLOR_BOLD}================================================================================${COLOR_RESET}
${COLOR_BOLD}        Ops-Monitor Docker 容器实时资源监控 (Docker Stats)                      ${COLOR_RESET}
${COLOR_BOLD}================================================================================${COLOR_RESET}
  ${COLOR_BOLD}主机节点:${COLOR_RESET} ${COLOR_CYAN}${host}${COLOR_RESET}          ${COLOR_BOLD}采样时间:${COLOR_RESET} ${cur_time}
  ${COLOR_BOLD}容器概况:${COLOR_RESET} ${COLOR_GREEN}${running_containers} 运行中${COLOR_RESET} / ${COLOR_YELLOW}${stopped_containers} 已停止${COLOR_RESET} / 共 ${total_containers} 个容器
  ${COLOR_BOLD}资源汇总:${COLOR_RESET} Docker CPU 总计: ${COLOR_CYAN}${total_cpu_pct}%${COLOR_RESET}  |  活跃容器: ${COLOR_GREEN}${active_count}${COLOR_RESET} 个

${COLOR_BOLD}--- 容器实时资源占用明细 ---${COLOR_RESET}
EOF

    # 打印对齐表头
    printf "%s%-22s %-14s %-12s %-22s %-12s %-17s %-17s %-6s%s\n" \
        "${COLOR_BOLD}" "CONTAINER (NAME)" "STATUS" "CPU %" "MEM USAGE / LIMIT" "MEM %" "NET I/O" "BLOCK I/O" "PIDS" "${COLOR_RESET}"
    echo -e "${COLOR_DIM}────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────${COLOR_RESET}"

    if [[ -n "${stats_data}" ]]; then
        while IFS=$'\t' read -r cid cname cpu_perc mem_usage mem_perc net_io block_io pids || [[ -n "${cid}" ]]; do
            [[ -z "${cid}" ]] && continue

            # 截取容器名称（若超过 20 字符）
            local disp_name="${cname}"
            if [[ ${#disp_name} -gt 21 ]]; then
                disp_name="${disp_name:0:18}..."
            fi

            # 状态提取与格式化
            local raw_status="${container_status_map[${cname}]:-${container_status_map[${cid}]:-Up}}"
            local disp_status="${raw_status}"
            if [[ ${#disp_status} -gt 13 ]]; then
                disp_status="${disp_status:0:12}…"
            fi

            # CPU 数值与颜色
            local cpu_val="${cpu_perc%%%}"
            cpu_val=$(echo "${cpu_val}" | tr -d '[:space:]')
            local cpu_col="${COLOR_GREEN}"
            local cpu_bar="░"
            local cpu_int=0
            cpu_int=$(awk -v v="${cpu_val}" 'BEGIN { iv=int(v+0.5); print (iv>100?100:iv) }')
            if [[ "${cpu_int}" -ge 80 ]]; then
                cpu_col="${COLOR_RED}"
                cpu_bar="█"
            elif [[ "${cpu_int}" -ge 40 ]]; then
                cpu_col="${COLOR_YELLOW}"
                cpu_bar="▄"
            elif [[ "${cpu_int}" -gt 5 ]]; then
                cpu_bar="▂"
            fi

            # 内存数值与颜色
            local mem_val="${mem_perc%%%}"
            mem_val=$(echo "${mem_val}" | tr -d '[:space:]')
            local mem_col="${COLOR_GREEN}"
            local mem_bar="░"
            local mem_int=0
            mem_int=$(awk -v v="${mem_val}" 'BEGIN { iv=int(v+0.5); print (iv>100?100:iv) }')
            if [[ "${mem_int}" -ge 85 ]]; then
                mem_col="${COLOR_RED}"
                mem_bar="█"
            elif [[ "${mem_int}" -ge 60 ]]; then
                mem_col="${COLOR_YELLOW}"
                mem_bar="▄"
            elif [[ "${mem_int}" -gt 5 ]]; then
                mem_bar="▂"
            fi

            # 格式化内存占用
            local disp_mem_usage="${mem_usage}"
            if [[ ${#disp_mem_usage} -gt 21 ]]; then
                disp_mem_usage="${disp_mem_usage:0:20}…"
            fi

            # 格式化网络 I/O
            local disp_net_io="${net_io}"
            if [[ ${#disp_net_io} -gt 16 ]]; then
                disp_net_io="${disp_net_io:0:15}…"
            fi

            # 格式化磁盘 I/O
            local disp_blk_io="${block_io}"
            if [[ ${#disp_blk_io} -gt 16 ]]; then
                disp_blk_io="${disp_blk_io:0:15}…"
            fi

            printf "%-22s %-14s %s%6.2f%% [%s]%s %-22s %s%6.2f%% [%s]%s %-17s %-17s %-6s\n" \
                "${disp_name}" \
                "${disp_status}" \
                "${cpu_col}" "${cpu_val:-0.00}" "${cpu_bar}" "${COLOR_RESET}" \
                "${disp_mem_usage}" \
                "${mem_col}" "${mem_val:-0.00}" "${mem_bar}" "${COLOR_RESET}" \
                "${disp_net_io}" \
                "${disp_blk_io}" \
                "${pids:-0}"
        done <<< "${stats_data}"
    fi

    echo -e "${COLOR_BOLD}================================================================================${COLOR_RESET}"
    echo -e "  ${COLOR_DIM}提示: 运行 'ops docker -w' 进入动态实时刷新看板  |  运行 'ops status' 查看系统健康${COLOR_RESET}"
}

# ------------------------------------------------------------------------------
# 5. 全屏 TUI 实时动态刷新看板 (Live Mode)
# ------------------------------------------------------------------------------
ops_docker_live() {
    local d_cmd
    d_cmd=$(_ops_docker_get_cmd)
    local ret=$?

    if [[ "${ret}" -ne 0 ]]; then
        ops_docker_check_environment
        return "${ret}"
    fi

    local refresh_interval="${1:-2}"
    [[ "${refresh_interval}" -lt 1 ]] && refresh_interval=2

    # 优雅退出钩子：恢复光标与终端回显
    cleanup_docker_tui() {
        printf "\033[?25h\033[0m\n"
        stty echo icanon 2>/dev/null || true
    }
    trap cleanup_docker_tui INT TERM EXIT

    # 隐藏光标并初次清屏
    stty -echo 2>/dev/null || true
    printf "\033[?25l\033[2J\033[H"

    while true; do
        printf "\033[H"
        ops_docker_show_overview
        printf "\033[J"

        local key=""
        read -s -n 1 -t "${refresh_interval}" key 2>/dev/null || true
        if [[ "${key}" == "q" || "${key}" == "Q" ]]; then
            break
        elif [[ "${key}" == "r" || "${key}" == "R" ]]; then
            continue
        fi
    done
}

# ------------------------------------------------------------------------------
# 6. Docker 统一 CLI 调度器
# ------------------------------------------------------------------------------
ops_docker_cli() {
    local action="${1:-}"
    shift 2>/dev/null || true

    case "${action}" in
        -w|-f|--live|live|watch|top)
            ops_docker_live "$@"
            ;;
        -h|--help|help)
            cat <<EOF
${COLOR_BOLD}Ops-Monitor Docker 实时资源监控使用帮助${COLOR_RESET}

${COLOR_BOLD}用法:${COLOR_RESET}
  ops docker                [默认] 输出当前所有 Docker 容器的资源占用体检卡片 (快照)
  ops docker -w, --live     启动动态实时刷新看板 (每 2 秒原位刷新，按 q 退出)
  ops docker -h, --help     打印此帮助信息

${COLOR_BOLD}快捷别名:${COLOR_RESET}
  ops ps                    等同于 ops docker
  ops containers            等同于 ops docker
EOF
            ;;
        ""|status|ps|stats|list)
            ops_docker_show_overview
            ;;
        *)
            ops_docker_show_overview
            ;;
    esac
}
