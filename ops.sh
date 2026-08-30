#!/usr/bin/env bash
# ==============================================================================
# Ops-Monitor 统一 CLI 调度器与主入口 (ops.sh)
# 终端命令行路由、全屏 TUI 实时看板、单次健康体检、历史大图与配置中心
# ==============================================================================

# 项目根路径推导 (解析多层软链接，准确定位源码真实物理路径)
_SRC="${BASH_SOURCE[0]}"
while [[ -L "${_SRC}" ]]; do
    _TARGET="$(readlink "${_SRC}")"
    if [[ "${_TARGET}" == /* ]]; then
        _SRC="${_TARGET}"
    else
        _SRC="$(dirname "${_SRC}")/${_TARGET}"
    fi
done
_OPS_ROOT="$(cd "$(dirname "${_SRC}")" && pwd)"
export OPS_BASE_DIR="${_OPS_ROOT}"
unset _SRC _TARGET

# 加载全量核心库
# shellcheck source=lib/common.sh
source "${_OPS_ROOT}/lib/common.sh"
# shellcheck source=lib/config_mgr.sh
source "${_OPS_ROOT}/lib/config_mgr.sh"
# shellcheck source=lib/collector.sh
source "${_OPS_ROOT}/lib/collector.sh"
# shellcheck source=lib/storage.sh
source "${_OPS_ROOT}/lib/storage.sh"
# shellcheck source=lib/webhook.sh
source "${_OPS_ROOT}/lib/webhook.sh"
# shellcheck source=lib/alert.sh
source "${_OPS_ROOT}/lib/alert.sh"
# shellcheck source=lib/render.sh
source "${_OPS_ROOT}/lib/render.sh"
# shellcheck source=lib/node_mgr.sh
source "${_OPS_ROOT}/lib/node_mgr.sh"
unset _OPS_ROOT

# ------------------------------------------------------------------------------
# 帮助信息与版本说明
# ------------------------------------------------------------------------------
ops_print_help() {
    cat <<EOF
${COLOR_BOLD}Ops-Monitor v${OPS_VERSION}${COLOR_RESET} - 轻量级服务器监控与多节点自动化运维套件 (Zero-Dependency)

${COLOR_BOLD}用法:${COLOR_RESET}
  ops [全局选项] <子命令> [参数...]
  ops <节点名称>              [快捷方式] 直接打开远程已注册服务器的实时监控看板

${COLOR_BOLD}本地监控与可视化:${COLOR_RESET}
  ${COLOR_CYAN}ops${COLOR_RESET}, ${COLOR_CYAN}ops dashboard${COLOR_RESET}        [默认] 启动全屏 TUI 实时动态监控看板 (丝滑无闪烁)
  ${COLOR_CYAN}ops status${COLOR_RESET}                  输出紧凑的单次健康体检报告 (适合 MOTD / 远程探测)
  ${COLOR_CYAN}ops history <cpu|mem|disk|net>${COLOR_RESET}
                              以高精度 ASCII 坐标系绘制过去 24 小时的历史指标大图

${COLOR_BOLD}多服务器集群与一键切换 (SSH 多节点):${COLOR_RESET}
  ${COLOR_CYAN}ops switch${COLOR_RESET}, ${COLOR_CYAN}ops s${COLOR_RESET}             [推荐] 打开交互式服务器切换中心 (数字直达/一键换机)
  ${COLOR_CYAN}ops use <节点名称|local>${COLOR_RESET}    切换当前默认工作上下文 (后续所有命令默认指向该机)
  ${COLOR_CYAN}ops current${COLOR_RESET}                 查看当前默认工作服务器
  ${COLOR_CYAN}ops update [--all | <名称>]${COLOR_RESET} 一键批量热升级所有/指定远程服务器上的 Ops-Monitor
  ${COLOR_CYAN}ops node import-ssh${COLOR_RESET}         一键从 ~/.ssh/config 自动发现并批量导入所有主机
  ${COLOR_CYAN}ops node add [名称] <目标/SSH命令>${COLOR_RESET}
                              注册远程服务器 (支持: ops node add "ssh -i ~/key root@ip")
  ${COLOR_CYAN}ops node list${COLOR_RESET}               列出所有已注册的远程服务器节点
  ${COLOR_CYAN}ops node status <名称>${COLOR_RESET}      远程探测并输出指定服务器的健康体检卡片
  ${COLOR_CYAN}ops node dashboard <名称>${COLOR_RESET}   通过 SSH 直接在终端打开远程服务器的实时监控看板
  ${COLOR_CYAN}ops node connect <名称>${COLOR_RESET}, ${COLOR_CYAN}ops ssh <名称>${COLOR_RESET}
                              一键 SSH 登录切换到指定远程服务器
  ${COLOR_CYAN}ops node deploy <名称>${COLOR_RESET}      一键向远程服务器自动安装/部署 Ops-Monitor 套件
  ${COLOR_CYAN}ops node uninstall <名称>${COLOR_RESET}   一键远程卸载指定服务器上的 Ops-Monitor 套件
  ${COLOR_CYAN}ops node remove <名称>${COLOR_RESET}      删除已注册的远程节点

${COLOR_BOLD}配置管理中心:${COLOR_RESET}
  ${COLOR_CYAN}ops config${COLOR_RESET}                  进入交互式配置问答向导
  ${COLOR_CYAN}ops config list [--raw]${COLOR_RESET}     打印当前生效的所有配置项 (默认脱敏)
  ${COLOR_CYAN}ops config get <KEY>${COLOR_RESET}        获取指定配置项的值
  ${COLOR_CYAN}ops config set <KEY> <VAL>${COLOR_RESET}   修改指定配置项并保存 (自动校验合法性)
  ${COLOR_CYAN}ops config export [--base64 | --template | -f <file>]${COLOR_RESET}
                              导出配置：支持标准输出、Base64 单行密文或文件
  ${COLOR_CYAN}ops config import [--base64 <str> | -f <file> | -]${COLOR_RESET}
                              导入配置：支持 Base64 字符串、文件或标准输入
  ${COLOR_CYAN}ops config test-alert${COLOR_RESET}       向已配置的 Webhook 通道发送一条模拟告警卡片

${COLOR_BOLD}生命周期与服务控制:${COLOR_RESET}
  ${COLOR_CYAN}ops archive --run${COLOR_RESET}           立即执行一次过期历史指标压缩归档与清理
  ${COLOR_CYAN}ops daemon <start|stop|restart|status>${COLOR_RESET}
                              管理后台采集与告警守护进程

${COLOR_BOLD}全局选项:${COLOR_RESET}
  -c, --config <path>         显式指定生效的配置文件路径
  -h, --help                  打印此帮助信息
  -v, --version               打印套件版本号
EOF
}

ops_print_version() {
    echo "Ops-Monitor v${OPS_VERSION} (POSIX/Bash Zero-Dependency Edition)"
}

# ------------------------------------------------------------------------------
# 全屏 TUI 动态看板
# ------------------------------------------------------------------------------
ops_run_dashboard() {
    local refresh_interval
    refresh_interval=$(ops_config_get "COLLECT_INTERVAL" "2")
    if [[ "${refresh_interval}" -gt 3 ]]; then
        # 仪表盘前台交互默认采用更流畅的 2 秒刷新
        refresh_interval=2
    fi

    # 优雅退出钩子：恢复光标与终端回显
    cleanup_tui() {
        printf "\033[?25h\033[0m\n"
        stty echo icanon 2>/dev/null || true
    }
    trap cleanup_tui INT TERM EXIT

    # 隐藏光标并初次清屏
    stty -echo 2>/dev/null || true
    printf "\033[?25l\033[2J\033[H"

    local host
    host=$(_ops_get_hostname)

    while true; do
        # 1. 采集指标 (0.3s 快速差分，确保前台交互极度流畅)
        local raw_tsv
        raw_tsv=$(ops_collect_metrics 0.3)
        ops_storage_append "${raw_tsv}"

        local ts cpu mem disk rx tx
        IFS=$'\t' read -r ts cpu mem disk rx tx <<< "${raw_tsv}"

        # 2. 评估告警
        ops_alert_evaluate_all "${cpu}" "${mem}" "${disk}" "${ts}"
        local overall_state
        overall_state=$(ops_alert_get_overall_status)

        local badge="${COLOR_BG_GREEN}${COLOR_WHITE} NORMAL ${COLOR_RESET}"
        if [[ "${overall_state}" == "CRITICAL" ]]; then
            badge="${COLOR_BG_RED}${COLOR_WHITE} CRITICAL ${COLOR_RESET}"
        elif [[ "${overall_state}" == "WARN" ]]; then
            badge="${COLOR_BG_YELLOW}${COLOR_WHITE} WARNING ${COLOR_RESET}"
        fi

        # 3. 提取历史火花线数据
        local recent_tsv
        recent_tsv=$(ops_storage_read_records "today" 30)
        local recent_cpus="" recent_mems=""
        if [[ -n "${recent_tsv}" ]]; then
            recent_cpus=$(echo "${recent_tsv}" | awk -F'\t' '{print $2}' | tr '\n' ' ')
            recent_mems=$(echo "${recent_tsv}" | awk -F'\t' '{print $3}' | tr '\n' ' ')
        fi
        [[ -z "${recent_cpus}" ]] && recent_cpus="${cpu}"
        [[ -z "${recent_mems}" ]] && recent_mems="${mem}"

        local spark_cpu spark_mem
        spark_cpu=$(ops_render_sparkline "${recent_cpus}" 0 100 1)
        spark_mem=$(ops_render_sparkline "${recent_mems}" 0 100 1)

        # 4. 原位刷新 (光标移至 0,0，绝不调用 clear，完全消除黑屏闪烁)
        printf "\033[H"

        cat <<EOF
${COLOR_BOLD}================================================================================${COLOR_RESET}
${COLOR_BOLD}  Ops-Monitor 实时性能看板                       状态: [${badge}${COLOR_BOLD}]  v${OPS_VERSION}${COLOR_RESET}
${COLOR_BOLD}================================================================================${COLOR_RESET}
  ${COLOR_BOLD}主机节点:${COLOR_RESET} ${COLOR_CYAN}${host}${COLOR_RESET}          ${COLOR_BOLD}当前时间:${COLOR_RESET} $(date '+%Y-%m-%d %H:%M:%S')
  ${COLOR_BOLD}系统运行:${COLOR_RESET} $(uptime -p 2>/dev/null || uptime | awk -F',' '{print $1}')

${COLOR_BOLD}--- 核心资源监控 ---${COLOR_RESET}
  CPU  使用率: $(ops_render_progress_bar "${cpu}" 20 1)   ${COLOR_DIM}近期趋势:${COLOR_RESET} ${spark_cpu}
  内存 使用率: $(ops_render_progress_bar "${mem}" 20 1)   ${COLOR_DIM}近期趋势:${COLOR_RESET} ${spark_mem}
  磁盘 使用率: $(ops_render_progress_bar "${disk}" 20 1)

${COLOR_BOLD}--- 网络实时吞吐 ---${COLOR_RESET}
  下行 (RX): ${COLOR_GREEN}${rx} KB/s${COLOR_RESET}
  上行 (TX): ${COLOR_CYAN}${tx} KB/s${COLOR_RESET}

${COLOR_BOLD}================================================================================${COLOR_RESET}
  ${COLOR_DIM}按 [q] 退出看板  |  按 [s] 切换服务器  |  按 [r] 强制刷新  |  按 [h] 查看帮助${COLOR_RESET}
EOF
        printf "\033[J"

        # 5. 等待按键 (支持毫秒级响应)
        local key=""
        read -s -n 1 -t "${refresh_interval}" key 2>/dev/null || true
        if [[ "${key}" == "q" || "${key}" == "Q" ]]; then
            break
        elif [[ "${key}" == "s" || "${key}" == "S" ]]; then
            printf "\033[2J\033[H\033[?25h"
            ops_node_switch
            printf "\033[2J\033[H\033[?25l"
            host=$(_ops_get_hostname)
        elif [[ "${key}" == "r" || "${key}" == "R" ]]; then
            continue
        elif [[ "${key}" == "h" || "${key}" == "H" ]]; then
            printf "\033[2J\033[H"
            ops_print_help
            echo ""
            read -r -p "按回车键返回看板..." _
            printf "\033[2J\033[H"
        fi
    done
}

# ------------------------------------------------------------------------------
# 交互式配置问答向导
# ------------------------------------------------------------------------------
ops_run_config_wizard() {
    echo -e "${COLOR_BOLD}=== Ops-Monitor 交互式配置向导 ===${COLOR_RESET}\n"
    ops_config_load

    local cur_cpu cur_mem cur_disk cur_cooldown
    cur_cpu=$(ops_config_get "ALERT_CPU_THRESHOLD" "85")
    cur_mem=$(ops_config_get "ALERT_MEM_THRESHOLD" "90")
    cur_disk=$(ops_config_get "ALERT_DISK_THRESHOLD" "85")
    cur_cooldown=$(ops_config_get "ALERT_COOLDOWN_MINUTES" "30")

    read -r -p "CPU 告警阈值 (%) [当前: ${cur_cpu}]: " in_cpu
    [[ -n "${in_cpu}" ]] && ops_config_set "ALERT_CPU_THRESHOLD" "${in_cpu}"

    read -r -p "内存 告警阈值 (%) [当前: ${cur_mem}]: " in_mem
    [[ -n "${in_mem}" ]] && ops_config_set "ALERT_MEM_THRESHOLD" "${in_mem}"

    read -r -p "磁盘 告警阈值 (%) [当前: ${cur_disk}]: " in_disk
    [[ -n "${in_disk}" ]] && ops_config_set "ALERT_DISK_THRESHOLD" "${in_disk}"

    read -r -p "告警冷却静默时间 (分钟) [当前: ${cur_cooldown}]: " in_cooldown
    [[ -n "${in_cooldown}" ]] && ops_config_set "ALERT_COOLDOWN_MINUTES" "${in_cooldown}"

    echo ""
    echo -e "${COLOR_BOLD}--- Webhook 配置 (留空跳过) ---${COLOR_RESET}"
    read -r -p "Slack Webhook URL: " in_slack
    [[ -n "${in_slack}" ]] && ops_config_set "WEBHOOK_SLACK_URL" "${in_slack}"

    read -r -p "钉钉 Webhook URL: " in_ding
    [[ -n "${in_ding}" ]] && ops_config_set "WEBHOOK_DINGTALK_URL" "${in_ding}"
    if [[ -n "${in_ding}" ]]; then
        read -r -p "钉钉 加签 Secret: " in_ding_sec
        [[ -n "${in_ding_sec}" ]] && ops_config_set "WEBHOOK_DINGTALK_SECRET" "${in_ding_sec}"
    fi

    read -r -p "飞书 Webhook URL: " in_feishu
    [[ -n "${in_feishu}" ]] && ops_config_set "WEBHOOK_FEISHU_URL" "${in_feishu}"

    read -r -p "企业微信 Webhook URL: " in_wecom
    [[ -n "${in_wecom}" ]] && ops_config_set "WEBHOOK_WECOM_URL" "${in_wecom}"

    echo -e "\n${COLOR_GREEN}配置已成功更新并加固保存！${COLOR_RESET}"
}

# ------------------------------------------------------------------------------
# 后台常驻守护进程执行循环 (Systemd / Cron 调用)
# ------------------------------------------------------------------------------
ops_daemon_loop() {
    ops_log_info "ops-daemon 守护进程启动 (PID: $$)..."
    
    local running=1
    trap 'running=0; ops_log_info "收到终止信号，ops-daemon 正在退出..."; exit 0' INT TERM

    while [[ "${running}" -eq 1 ]]; do
        local interval
        interval=$(ops_config_get "COLLECT_INTERVAL" "60")
        [[ "${interval}" -lt 1 ]] && interval=60

        # 1. 采集并落盘
        local raw_tsv
        raw_tsv=$(ops_collect_metrics 1)
        if [[ -n "${raw_tsv}" ]]; then
            ops_storage_append "${raw_tsv}"

            # 2. 告警规则比对与状态机推进
            local ts cpu mem disk rx tx
            IFS=$'\t' read -r ts cpu mem disk rx tx <<< "${raw_tsv}"
            ops_alert_evaluate_all "${cpu}" "${mem}" "${disk}" "${ts}"
        fi

        # 3. 每日历史归档检查
        ops_storage_archive 0

        # 4. 休眠至下一周期 (支持信号唤醒中断)
        sleep "${interval}" &
        wait $! 2>/dev/null || true
    done
}

ops_cron_step() {
    local raw_tsv
    raw_tsv=$(ops_collect_metrics 1)
    if [[ -n "${raw_tsv}" ]]; then
        ops_storage_append "${raw_tsv}"

        local ts cpu mem disk rx tx
        IFS=$'\t' read -r ts cpu mem disk rx tx <<< "${raw_tsv}"
        ops_alert_evaluate_all "${cpu}" "${mem}" "${disk}" "${ts}"
    fi
    ops_storage_archive 0
}

# ------------------------------------------------------------------------------
# 守护进程管理 (Systemd 优先，PID 文件降级)
# ------------------------------------------------------------------------------
ops_manage_daemon() {
    local action="${1:-status}"
    
    if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q "ops-daemon.service"; then
        case "${action}" in
            start)
                systemctl start ops-daemon.service
                ops_log_info "ops-daemon.service 已启动"
                ;;
            stop)
                systemctl stop ops-daemon.service
                ops_log_info "ops-daemon.service 已停止"
                ;;
            restart)
                systemctl restart ops-daemon.service
                ops_log_info "ops-daemon.service 已重启"
                ;;
            status)
                systemctl status ops-daemon.service --no-pager
                ;;
            *)
                ops_log_err "未知守护进程动作: ${action} (支持: start, stop, restart, status)"
                return 1
                ;;
        esac
    else
        # 降级模式：纯后台循环与 PID 跟踪
        local pid_file="${OPS_RUN_DIR}/ops-daemon.pid"
        case "${action}" in
            start)
                if [[ -f "${pid_file}" ]] && kill -0 "$(cat "${pid_file}")" 2>/dev/null; then
                    ops_log_warn "ops-daemon 已经在后台运行 (PID: $(cat "${pid_file}"))"
                    return 0
                fi
                ops_ensure_dirs
                nohup bash "${OPS_BASE_DIR}/ops.sh" daemon-run >/dev/null 2>&1 &
                echo $! > "${pid_file}"
                ops_log_info "ops-daemon 降级后台进程已启动 (PID: $!)"
                ;;
            stop)
                if [[ -f "${pid_file}" ]]; then
                    local p
                    p=$(cat "${pid_file}")
                    kill "${p}" 2>/dev/null || true
                    rm -f "${pid_file}"
                    ops_log_info "ops-daemon (PID: ${p}) 已停止"
                else
                    ops_log_warn "未发现正在运行的 ops-daemon PID 文件"
                fi
                ;;
            status)
                if [[ -f "${pid_file}" ]] && kill -0 "$(cat "${pid_file}")" 2>/dev/null; then
                    echo "ops-daemon (降级模式) 正在运行 (PID: $(cat "${pid_file}"))"
                else
                    echo "ops-daemon 未在运行"
                fi
                ;;
            restart)
                ops_manage_daemon stop
                sleep 1
                ops_manage_daemon start
                ;;
            *)
                ops_log_err "未知动作: ${action}"
                return 1
                ;;
        esac
    fi
}

# ------------------------------------------------------------------------------
# CLI 参数主路由分发
# ------------------------------------------------------------------------------
main() {
    # 解析全局选项
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--config)
                export OPS_CONFIG_FILE="$2"
                shift 2
                ;;
            -h|--help)
                ops_print_help
                exit 0
                ;;
            -v|--version)
                ops_print_version
                exit 0
                ;;
            *)
                break
                ;;
        esac
    done

    local subcommand="${1:-dashboard}"
    shift 2>/dev/null || true

    case "${subcommand}" in
        dashboard)
            local active
            active=$(ops_node_get_active)
            if [[ "${active}" != "local" ]]; then
                ops_node_dashboard "${active}"
            else
                ops_run_dashboard "$@"
            fi
            ;;
        status)
            local active
            active=$(ops_node_get_active)
            if [[ "${active}" != "local" ]]; then
                ops_node_status "${active}"
            else
                ops_render_status_card
            fi
            ;;
        switch|select|s)
            ops_node_switch
            ;;
        use)
            ops_node_use "$@"
            ;;
        current|whoami)
            ops_node_use
            ;;
        update|upgrade)
            local update_target="${1:-}"
            if [[ -z "${update_target}" || "${update_target}" == "--all" || "${update_target}" == "-a" ]]; then
                ops_node_update_all "$@"
            else
                ops_node_deploy "${update_target}"
            fi
            ;;
        history)
            local active
            active=$(ops_node_get_active)
            if [[ "${active}" != "local" ]]; then
                ops_node_history "${active}" "$@"
            else
                local metric_target="${1:-cpu}"
                local date_target="${2:-today}"
                ops_render_history_chart "${metric_target}" "${date_target}"
            fi
            ;;
        config)
            local cfg_action="${1:-}"
            shift 2>/dev/null || true
            case "${cfg_action}" in
                get)
                    ops_config_get "$1" "$2"
                    ;;
                set)
                    ops_config_set "$1" "$2"
                    ;;
                list)
                    local is_raw=0
                    [[ "${1:-}" == "--raw" ]] && is_raw=1
                    ops_config_list "${is_raw}"
                    ;;
                export)
                    local fmt="plain"
                    local out_file=""
                    while [[ $# -gt 0 ]]; do
                        case "$1" in
                            --base64) fmt="base64"; shift ;;
                            --template) fmt="template"; shift ;;
                            -f|--file) out_file="$2"; shift 2 ;;
                            *) shift ;;
                        esac
                    done
                    ops_config_export "${fmt}" "${out_file}"
                    ;;
                import)
                    local src_type="base64"
                    local input_val=""
                    while [[ $# -gt 0 ]]; do
                        case "$1" in
                            --base64) src_type="base64"; input_val="$2"; shift 2 ;;
                            -f|--file) src_type="file"; input_val="$2"; shift 2 ;;
                            -) src_type="stdin"; shift ;;
                            *) input_val="$1"; shift ;;
                        esac
                    done
                    ops_config_import "${src_type}" "${input_val}"
                    ;;
                test-alert)
                    ops_webhook_test_alert
                    ;;
                "")
                    ops_run_config_wizard
                    ;;
                *)
                    ops_log_err "未知 config 子命令: ${cfg_action}"
                    exit "${OPS_EXIT_CONFIG_ERR}"
                    ;;
            esac
            ;;
        archive)
            local run_flag="${1:-}"
            if [[ "${run_flag}" == "--run" ]]; then
                ops_storage_archive 1
                ops_log_info "手动归档执行完成"
            else
                echo "用法: ops archive --run"
            fi
            ;;
        daemon)
            ops_manage_daemon "$@"
            ;;
        daemon-run)
            ops_daemon_loop
            ;;
        cron-run)
            ops_cron_step
            ;;
        node|nodes)
            local node_action="${1:-list}"
            shift 2>/dev/null || true
            case "${node_action}" in
                add)
                    ops_node_add "$@"
                    ;;
                list)
                    ops_node_list
                    ;;
                switch|select)
                    ops_node_switch
                    ;;
                use)
                    ops_node_use "$@"
                    ;;
                import-ssh)
                    ops_node_import_ssh
                    ;;
                remove|rm|del)
                    ops_node_remove "$1"
                    ;;
                status)
                    ops_node_status "$1"
                    ;;
                dashboard|top)
                    ops_node_dashboard "$1"
                    ;;
                connect)
                    ops_node_connect "$1"
                    ;;
                deploy|init)
                    ops_node_deploy "$1"
                    ;;
                update|update-all|upgrade)
                    ops_node_update_all "$@"
                    ;;
                uninstall|undeploy)
                    ops_node_uninstall "$1" "${2:-}"
                    ;;
                *)
                    echo "用法: ops node <add|list|switch|use|import-ssh|status|dashboard|connect|deploy|update-all|uninstall|remove> [参数]"
                    ;;
            esac
            ;;
        ssh)
            ops_node_connect "$1"
            ;;
        *)
            # 检查是否为已注册的远程节点名称 (例如: ops aws-prod -> 直接进入该远程节点仪表盘)
            if _ops_node_find "${subcommand}" >/dev/null 2>&1; then
                ops_node_dashboard "${subcommand}"
            else
                ops_log_err "未知命令 '${subcommand}'，请执行 'ops --help' 查看用法"
                exit "${OPS_EXIT_GENERAL}"
            fi
            ;;
    esac
}

main "$@"
