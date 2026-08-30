#!/usr/bin/env bash
# ==============================================================================
# Ops-Monitor 远程 SSH 节点管理与多服务器切换中心 (lib/node_mgr.sh)
# 支持一键切换服务器 (Switch)、全局上下文设置 (Use)、~/.ssh/config 自动导入与免输名称
# ==============================================================================

_NODE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${_NODE_LIB_DIR}/common.sh"
# shellcheck source=config_mgr.sh
source "${_NODE_LIB_DIR}/config_mgr.sh"
unset _NODE_LIB_DIR

# 节点注册表路径与活动上下文记录
OPS_NODES_FILE="${OPS_CONFIG_DIR}/nodes.conf"
OPS_ACTIVE_NODE_FILE="${OPS_CONFIG_DIR}/active_node"

# ------------------------------------------------------------------------------
# 节点注册表初始化
# 存储格式: NAME|TARGET|SSH_OPTS|DESCRIPTION
# ------------------------------------------------------------------------------
_ops_node_ensure_file() {
    local node_dir
    node_dir="$(dirname "${OPS_NODES_FILE}")"
    mkdir -p "${node_dir}" 2>/dev/null || true
    if [[ ! -f "${OPS_NODES_FILE}" ]]; then
        touch "${OPS_NODES_FILE}"
        echo "# Ops-Monitor 远程节点注册表 (权限: 0600)" > "${OPS_NODES_FILE}"
        echo "# 格式: NAME|TARGET|SSH_OPTS|DESCRIPTION" >> "${OPS_NODES_FILE}"
    fi
    ops_secure_file "${OPS_NODES_FILE}"
}

# ------------------------------------------------------------------------------
# 当前活动上下文获取与设置 (Context Switch)
# ------------------------------------------------------------------------------
ops_node_get_active() {
    if [[ -f "${OPS_ACTIVE_NODE_FILE}" ]]; then
        local cur
        cur=$(cat "${OPS_ACTIVE_NODE_FILE}" 2>/dev/null | tr -d '[:space:]')
        if [[ -n "${cur}" ]]; then
            echo "${cur}"
            return 0
        fi
    fi
    echo "local"
}

ops_node_use() {
    local name="${1:-}"
    if [[ -z "${name}" ]]; then
        local active
        active=$(ops_node_get_active)
        echo -e "当前默认活动服务器: ${COLOR_CYAN}${active}${COLOR_RESET}"
        echo -e "切换用法: ${COLOR_YELLOW}ops use <节点名称|local>${COLOR_RESET}"
        return 0
    fi

    if [[ "${name}" == "local" || "${name}" == "default" || "${name}" == "localhost" ]]; then
        rm -f "${OPS_ACTIVE_NODE_FILE}" 2>/dev/null || true
        ops_log_info "已切换工作上下文为: ${COLOR_GREEN}本地服务器 (local)${COLOR_RESET}"
        return 0
    fi

    local node_info
    node_info=$(_ops_node_find "${name}") || {
        ops_log_err "未找到已注册的节点 '${name}'。执行 'ops node list' 查看可用节点。"
        return 1
    }

    mkdir -p "$(dirname "${OPS_ACTIVE_NODE_FILE}")" 2>/dev/null || true
    echo "${name}" > "${OPS_ACTIVE_NODE_FILE}"
    ops_secure_file "${OPS_ACTIVE_NODE_FILE}"
    ops_log_info "已切换默认工作服务器为: ${COLOR_GREEN}${name}${COLOR_RESET} (${node_info%%|*})"
    echo -e "💡 提示: 现在直接输入 ${COLOR_BOLD}ops${COLOR_RESET} 或 ${COLOR_BOLD}ops status${COLOR_RESET} 将默认查看该远程服务器！"
}

# ------------------------------------------------------------------------------
# 1. 注册 / 添加远程服务器节点 (支持自动命名)
# ------------------------------------------------------------------------------
ops_node_add() {
    local name=""
    local raw_input="$*"

    # 智能判断：如果第一个参数包含 @ 或以 ssh 开头，表示用户未指定名称，直接输入了连接串
    if [[ "${1:-}" =~ ^[A-Za-z0-9_.-]+@[A-Za-z0-9_.:-]+$ ]] || [[ "${1:-}" == ssh* ]] || [[ "${1:-}" =~ ^- ]] || [[ "${1:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        raw_input="$*"
        name=""
    else
        name="$1"
        shift 2>/dev/null || true
        raw_input="$*"
    fi

    # 去除开头的 "ssh "
    raw_input="${raw_input#ssh }"

    # 提取是否显式指定 --deploy 或 --no-deploy
    local flag_deploy=0
    local flag_no_deploy=0

    # 遍历参数寻找 user@host 或 host
    local args_arr=()
    read -r -a args_arr <<< "${raw_input}"
    
    local target=""
    local opts_builder=""
    local i=0
    while [[ $i -lt ${#args_arr[@]} ]]; do
        local arg="${args_arr[$i]}"
        if [[ "${arg}" == "--deploy" || "${arg}" == "-y" ]]; then
            flag_deploy=1
        elif [[ "${arg}" == "--no-deploy" || "${arg}" == "-n" ]]; then
            flag_no_deploy=1
        elif [[ "${arg}" =~ ^[A-Za-z0-9_.-]+@[A-Za-z0-9_.:-]+$ ]] || [[ "${arg}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            target="${arg}"
        elif [[ "${arg}" == "-i" || "${arg}" == "-p" || "${arg}" == "-P" || "${arg}" == "-F" || "${arg}" == "-l" ]]; then
            local next_idx=$(( i + 1 ))
            if [[ ${next_idx} -lt ${#args_arr[@]} ]]; then
                opts_builder+="${arg} ${args_arr[$next_idx]} "
                i=${next_idx}
            fi
        elif [[ "${arg}" =~ ^- ]]; then
            opts_builder+="${arg} "
        else
            if [[ -z "${target}" ]]; then
                target="${arg}"
            else
                opts_builder+="${arg} "
            fi
        fi
        i=$(( i + 1 ))
    done

    # 去除尾部空格并将 ~ 替换为实际 $HOME 绝对路径
    local ssh_opts="${opts_builder%"${opts_builder##*[![:space:]]}"}"
    ssh_opts="${ssh_opts/#\~/$HOME}"
    ssh_opts="${ssh_opts// \~\// $HOME\/}"

    if [[ -z "${target}" ]]; then
        ops_log_err "未能从参数中解析出 SSH 目标主机 (例如 root@35.78.207.248)"
        return 1
    fi

    # 如果用户没有给服务器起名字，自动生成或交互询问
    if [[ -z "${name}" ]]; then
        local raw_ip
        raw_ip=$(echo "${target}" | awk -F'@' '{print $NF}' | tr -d '[:space:]')
        local default_name="node-${raw_ip//./-}"
        if [[ -t 0 && "${flag_no_deploy}" != "1" ]]; then
            read -t 15 -r -p "请输入此服务器的别名 [回车默认: ${default_name}]: " user_name || user_name=""
            name="${user_name:-${default_name}}"
        else
            name="${default_name}"
        fi
    fi

    # 校验名称合法性
    if ! [[ "${name}" =~ ^[A-Za-z0-9_.-]+$ ]]; then
        ops_log_err "节点名称包含非法字符，仅允许英文、数字、中划线和下划线: '${name}'"
        return 1
    fi

    _ops_node_ensure_file

    # 移除旧的同名记录
    local tmp_file="${OPS_NODES_FILE}.tmp.$$"
    grep -v "^${name}|" "${OPS_NODES_FILE}" 2>/dev/null > "${tmp_file}" || true
    echo "${name}|${target}|${ssh_opts}|" >> "${tmp_file}"
    mv -f "${tmp_file}" "${OPS_NODES_FILE}"
    ops_secure_file "${OPS_NODES_FILE}"

    ops_log_info "节点已成功注册: ${COLOR_CYAN}${name}${COLOR_RESET} -> ${target} (参数: ${ssh_opts:-无})"

    # 询问是否立即远程安装
    if [[ "${flag_deploy}" == "1" ]]; then
        ops_node_deploy "${name}"
    elif [[ "${flag_no_deploy}" != "1" && -t 0 ]]; then
        echo ""
        read -t 15 -r -p "💡 是否现在立即通过 SSH 为远程机器 [${name}] 安装部署 Ops-Monitor 套件？[y/N]: " do_deploy || do_deploy="n"
        case "${do_deploy}" in
            y|Y|yes|YES)
                echo ""
                ops_node_deploy "${name}"
                ;;
            *)
                echo -e "  ${COLOR_DIM}已跳过安装。后续可随时运行 'ops node deploy ${name}' 进行一键安装。${COLOR_RESET}\n"
                ;;
        esac
    fi
    return 0
}

# ------------------------------------------------------------------------------
# 2. 列出所有已注册节点
# ------------------------------------------------------------------------------
ops_node_list() {
    _ops_node_ensure_file
    local active
    active=$(ops_node_get_active)

    echo -e "${COLOR_BOLD}======================= Ops-Monitor 服务器节点列表 =======================${COLOR_RESET}"
    printf "%-4s %-16s %-26s %-26s %-8s\n" "序号" "节点标识" "SSH 目标主机" "连接参数" "状态"
    echo "--------------------------------------------------------------------------------"

    # 显示本地节点
    local local_tag=""
    [[ "${active}" == "local" ]] && local_tag="${COLOR_GREEN}[当前活跃]${COLOR_RESET}"
    printf "%-4s %-16s %-26s %-26s %-8b\n" "[0]" "local (本机)" "127.0.0.1" "-" "${local_tag}"

    local idx=1
    local found=0
    while IFS='|' read -r name target opts desc || [[ -n "${name}" ]]; do
        [[ -z "${name}" || "${name}" =~ ^# ]] && continue
        local cur_tag=""
        [[ "${name}" == "${active}" ]] && cur_tag="${COLOR_GREEN}[当前活跃]${COLOR_RESET}"
        printf "%-4s %-16s %-26s %-26s %-8b\n" "[${idx}]" "${name}" "${target}" "${opts:--}" "${cur_tag}"
        idx=$(( idx + 1 ))
        found=1
    done < "${OPS_NODES_FILE}"
    echo "--------------------------------------------------------------------------------"
    echo -e "👉 快速切换服务器: ${COLOR_YELLOW}ops switch${COLOR_RESET}  |  设置默认服务器: ${COLOR_YELLOW}ops use <名称>${COLOR_RESET}\n"
}

# ------------------------------------------------------------------------------
# 3. 获取指定节点连接参数
# ------------------------------------------------------------------------------
_ops_node_find() {
    local name="$1"
    _ops_node_ensure_file

    while IFS='|' read -r n target opts desc || [[ -n "${n}" ]]; do
        [[ -z "${n}" || "${n}" =~ ^# ]] && continue
        if [[ "${n}" == "${name}" ]]; then
            echo "${target}|${opts}"
            return 0
        fi
    done < "${OPS_NODES_FILE}"

    return 1
}

# ------------------------------------------------------------------------------
# 4. 删除指定节点
# ------------------------------------------------------------------------------
ops_node_remove() {
    local name="$1"
    if [[ -z "${name}" ]]; then
        ops_log_err "请指定要删除的节点名称"
        return 1
    fi

    _ops_node_ensure_file
    local tmp_file="${OPS_NODES_FILE}.tmp.$$"
    grep -v "^${name}|" "${OPS_NODES_FILE}" 2>/dev/null > "${tmp_file}" || true
    mv -f "${tmp_file}" "${OPS_NODES_FILE}"
    ops_secure_file "${OPS_NODES_FILE}"

    # 若删除了当前活动节点，自动重置回 local
    local active
    active=$(ops_node_get_active)
    if [[ "${active}" == "${name}" ]]; then
        rm -f "${OPS_ACTIVE_NODE_FILE}" 2>/dev/null || true
    fi

    ops_log_info "已移除节点: ${name}"
}

# ------------------------------------------------------------------------------
# 5. SSH 直接连接登录节点
# ------------------------------------------------------------------------------
ops_node_connect() {
    local name="${1:-}"
    if [[ -z "${name}" ]]; then
        name=$(ops_node_get_active)
    fi

    if [[ "${name}" == "local" ]]; then
        ops_log_info "当前为本地服务器，无需 SSH 连接。"
        return 0
    fi

    local node_info
    node_info=$(_ops_node_find "${name}") || {
        ops_log_err "未找到节点 '${name}'，请先使用 'ops node add ${name} ...' 注册"
        return 1
    }

    local target opts
    target="${node_info%%|*}"
    opts="${node_info#*|}"

    ops_log_info "正在连接至远程节点: ${COLOR_CYAN}${name}${COLOR_RESET} (${target})..."
    # shellcheck disable=SC2086
    ssh ${opts} "${target}"
}

# ------------------------------------------------------------------------------
# 6. 远程查看目标节点健康状态 (ops node status <name>)
# ------------------------------------------------------------------------------
ops_node_status() {
    local name="${1:-}"
    if [[ -z "${name}" ]]; then
        name=$(ops_node_get_active)
    fi

    if [[ "${name}" == "local" ]]; then
        ops_render_status_card
        return 0
    fi

    local node_info
    node_info=$(_ops_node_find "${name}") || {
        ops_log_err "未找到节点 '${name}'"
        return 1
    }

    local target opts
    target="${node_info%%|*}"
    opts="${node_info#*|}"

    ops_log_info "正在探测远程节点健康体检: ${COLOR_CYAN}${name}${COLOR_RESET}..."
    
    # 优先执行远端已安装的 ops status；若未安装则执行快速内建探针
    # shellcheck disable=SC2086
    ssh -o ConnectTimeout=5 ${opts} "${target}" "
        if command -v ops >/dev/null 2>&1; then
            ops status
        else
            echo '┌────────────────────────────────────────────────────────────────────────┐'
            echo '│  [远程探测] 主机: \$(hostname) (未安装 Ops-Monitor)'
            echo '├────────────────────────────────────────────────────────────────────────┤'
            echo '│  运行时间: \$(uptime -p 2>/dev/null || uptime)'
            echo '│  CPU 核心: \$(nproc 2>/dev/null || grep -c processor /proc/cpuinfo 2>/dev/null)'
            echo '│  内存空闲: \$(free -m 2>/dev/null | awk \"NR==2{print \\\$3\\\"MB / \\\"\\\$2\\\"MB (\\\"int(\\\$3*100/\\\$2)\\\"%)\\\"}\")'
            echo '│  磁盘分区: \$(df -h / 2>/dev/null | awk \"NR==2{print \\\$3\\\" / \\\"\\\$2\\\" (\\\"\\\$5\\\")\\\"}\")'
            echo '└────────────────────────────────────────────────────────────────────────┘'
            echo '💡 提示: 执行 \"ops node deploy ${name}\" 可一键为该远程机器安装 Ops-Monitor'
        fi
    "
}

# ------------------------------------------------------------------------------
# 7. 打开远程节点全屏实时看板 (ops node dashboard <name>)
# ------------------------------------------------------------------------------
ops_node_dashboard() {
    local name="${1:-}"
    if [[ -z "${name}" ]]; then
        name=$(ops_node_get_active)
    fi

    if [[ "${name}" == "local" ]]; then
        ops_run_dashboard
        return 0
    fi

    local node_info
    node_info=$(_ops_node_find "${name}") || {
        ops_log_err "未找到节点 '${name}'"
        return 1
    }

    local target opts
    target="${node_info%%|*}"
    opts="${node_info#*|}"

    # shellcheck disable=SC2086
    ssh -t ${opts} "${target}" "
        if command -v ops >/dev/null 2>&1; then
            ops dashboard
        else
            echo '未在远程服务器上找到 ops 命令。'
            echo '请先执行 \"ops node deploy ${name}\" 一键部署套件。'
        fi
    "
}

# ------------------------------------------------------------------------------
# 8. 打开远程节点 24 小时历史趋势大图 (ops node history <name> [cpu|mem|disk|net])
# ------------------------------------------------------------------------------
ops_node_history() {
    local name="${1:-}"
    shift 2>/dev/null || true
    if [[ -z "${name}" ]]; then
        name=$(ops_node_get_active)
    fi

    if [[ "${name}" == "local" ]]; then
        local metric_target="${1:-cpu}"
        local date_target="${2:-today}"
        ops_render_history_chart "${metric_target}" "${date_target}"
        return 0
    fi

    local node_info
    node_info=$(_ops_node_find "${name}") || {
        ops_log_err "未找到节点 '${name}'"
        return 1
    }

    local target opts
    target="${node_info%%|*}"
    opts="${node_info#*|}"

    # shellcheck disable=SC2086
    ssh -t ${opts} "${target}" "ops history $*"
}

# ------------------------------------------------------------------------------
# 9. 一键远程部署 Ops-Monitor 至目标节点 (ops node deploy <name>)
# ------------------------------------------------------------------------------
ops_node_deploy() {
    local name="$1"
    local node_info
    node_info=$(_ops_node_find "${name}") || {
        ops_log_err "未找到节点 '${name}'"
        return 1
    }

    local target opts
    target="${node_info%%|*}"
    opts="${node_info#*|}"

    ops_log_info "正在向远程节点 ${COLOR_CYAN}${name}${COLOR_RESET} (${target}) 部署 Ops-Monitor..."

    # 优先传输本地构建的 deb 包或运行源码 install.sh
    local local_deb="${OPS_BASE_DIR}/dist/ops-monitor_1.0.0_all.deb"
    if [[ -f "${local_deb}" ]]; then
        ops_log_info "通过 SSH 数据流分发本地 deb 安装包..."
        # shellcheck disable=SC2086
        if cat "${local_deb}" | ssh ${opts} "${target}" "
            cat > /tmp/ops-monitor.deb &&
            (sudo dpkg -i /tmp/ops-monitor.deb 2>/dev/null || sudo apt-get install -f -y /tmp/ops-monitor.deb) &&
            rm -f /tmp/ops-monitor.deb &&
            echo '安装成功！'
        "; then
            ops_log_info "远程节点 ${name} 部署成功！"
        else
            ops_log_err "远程部署失败，请检查 SSH 连接与 sudo 权限。"
            return 1
        fi
    else
        ops_log_info "通过官方安装自举脚本远程安装..."
        # shellcheck disable=SC2086
        ssh ${opts} "${target}" "curl -fsSL https://raw.githubusercontent.com/xzsean666/Ops-Monitor/main/install.sh | sudo bash"
    fi

    ops_log_info "远程节点 ${name} 部署完毕！现在可直接执行: ${COLOR_GREEN}ops ${name}${COLOR_RESET} 查看远程实时看板"
}

# ------------------------------------------------------------------------------
# 10. 一键远程卸载目标节点的 Ops-Monitor (ops node uninstall <name> [--purge])
# ------------------------------------------------------------------------------
ops_node_uninstall() {
    local name="$1"
    local purge_flag="${2:-}"
    local node_info
    node_info=$(_ops_node_find "${name}") || {
        ops_log_err "未找到节点 '${name}'"
        return 1
    }

    local target opts
    target="${node_info%%|*}"
    opts="${node_info#*|}"

    local purge_arg=""
    [[ "${purge_flag}" == "--purge" ]] && purge_arg="--purge"

    ops_log_info "正在向远程节点 ${COLOR_CYAN}${name}${COLOR_RESET} (${target}) 执行卸载..."

    # shellcheck disable=SC2086
    ssh -t ${opts} "${target}" "
        if command -v apt-get >/dev/null 2>&1 && dpkg -l ops-monitor >/dev/null 2>&1; then
            if [ '${purge_flag}' = '--purge' ]; then
                sudo apt-get purge -y ops-monitor
            else
                sudo apt-get remove -y ops-monitor
            fi
        elif [ -f /opt/ops-monitor/uninstall.sh ]; then
            sudo bash /opt/ops-monitor/uninstall.sh ${purge_arg}
        else
            echo '远程节点上未发现已安装的 Ops-Monitor。'
        fi
    "
    ops_log_info "远程节点 ${name} 卸载完成。"
}

# ------------------------------------------------------------------------------
# 11. 从 ~/.ssh/config 自动发现并批量导入所有服务器
# ------------------------------------------------------------------------------
ops_node_import_ssh() {
    local ssh_cfg="${HOME}/.ssh/config"
    if [[ ! -f "${ssh_cfg}" ]]; then
        ops_log_err "未找到 SSH 配置文件: ${ssh_cfg}"
        return 1
    fi

    ops_log_info "正在扫描并导入 ${ssh_cfg} 中的服务器配置..."

    local count=0
    local cur_host="" cur_hostname="" cur_user="" cur_port="" cur_key=""

    _save_parsed_host() {
        if [[ -n "${cur_host}" && "${cur_host}" != "*" ]]; then
            local host_target="${cur_hostname:-${cur_host}}"
            [[ -n "${cur_user}" ]] && host_target="${cur_user}@${host_target}"
            
            local opts=""
            [[ -n "${cur_port}" ]] && opts+="-p ${cur_port} "
            [[ -n "${cur_key}" ]] && opts+="-i ${cur_key} "
            
            ops_node_add "${cur_host}" "${host_target} ${opts}" --no-deploy >/dev/null 2>&1
            echo -e "  ✔ 导入节点: ${COLOR_CYAN}${cur_host}${COLOR_RESET} (${host_target})"
            count=$(( count + 1 ))
        fi
    }

    while read -r line || [[ -n "${line}" ]]; do
        line="$(echo "${line}" | tr -d '\r' | sed 's/^[ \t]*//')"
        [[ -z "${line}" || "${line}" =~ ^# ]] && continue
        
        local key val
        key=$(echo "${line}" | awk '{print tolower($1)}')
        val=$(echo "${line}" | awk '{$1=""; print $0}' | sed 's/^[ \t]*//')

        if [[ "${key}" == "host" ]]; then
            _save_parsed_host
            cur_host="${val}"
            cur_hostname=""
            cur_user=""
            cur_port=""
            cur_key=""
        elif [[ "${key}" == "hostname" ]]; then
            cur_hostname="${val}"
        elif [[ "${key}" == "user" ]]; then
            cur_user="${val}"
        elif [[ "${key}" == "port" ]]; then
            cur_port="${val}"
        elif [[ "${key}" == "identityfile" ]]; then
            cur_key="${val}"
        fi
    done < "${ssh_cfg}"
    _save_parsed_host

    ops_log_info "SSH 配置扫描完成，成功导入 ${count} 台服务器！"
}

# ------------------------------------------------------------------------------
# ------------------------------------------------------------------------------
# 12. 一键批量向所有已注册的远程服务器更新/部署 Ops-Monitor (ops update --all)
# ------------------------------------------------------------------------------
ops_node_update_all() {
    _ops_node_ensure_file

    # 1. 自动预先构建最新 deb 包
    if [[ -f "${OPS_BASE_DIR}/build-deb.sh" ]]; then
        ops_log_info "正在本地打包最新的 Ops-Monitor 安装包..."
        bash "${OPS_BASE_DIR}/build-deb.sh" >/dev/null 2>&1 || true
    fi

    local node_names=()
    local node_targets=()
    while IFS='|' read -r name target opts desc || [[ -n "${name}" ]]; do
        [[ -z "${name}" || "${name}" =~ ^# ]] && continue
        node_names+=("${name}")
        node_targets+=("${target}")
    done < "${OPS_NODES_FILE}"

    local total=${#node_names[@]}
    if [[ "${total}" -eq 0 ]]; then
        ops_log_warn "当前未注册任何远程服务器节点。请先使用 'ops node add' 添加服务器。"
        return 0
    fi

    echo -e "${COLOR_BOLD}================================================================================${COLOR_RESET}"
    echo -e "${COLOR_BOLD}            Ops-Monitor 服务器集群一键批量更新 (Update All)                      ${COLOR_RESET}"
    echo -e "${COLOR_BOLD}================================================================================${COLOR_RESET}"
    echo -e "准备升级以下 ${COLOR_CYAN}${total}${COLOR_RESET} 台服务器:\n"

    local i=0
    while [[ $i -lt $total ]]; do
        printf "  • %-16s -> %s\n" "${node_names[$i]}" "${node_targets[$i]}"
        i=$(( i + 1 ))
    done
    echo ""

    if [[ -t 0 && "${1:-}" != "-y" && "${1:-}" != "--yes" ]]; then
        read -r -p "💡 确认一键升级上述所有服务器？[Y/n]: " confirm || confirm="y"
        if [[ "${confirm}" == "n" || "${confirm}" == "N" ]]; then
            echo "已取消批量升级。"
            return 0
        fi
        echo ""
    fi

    local success_count=0
    local fail_count=0
    local failed_nodes=()

    i=0
    while [[ $i -lt $total ]]; do
        local cur_name="${node_names[$i]}"
        local cur_target="${node_targets[$i]}"
        local step=$(( i + 1 ))

        echo -e "${COLOR_CYAN}[${step}/${total}] 正在升级: ${COLOR_BOLD}${cur_name}${COLOR_RESET} (${cur_target})...${COLOR_RESET}"
        if ops_node_deploy "${cur_name}" >/dev/null 2>&1; then
            echo -e "  ${COLOR_GREEN}✔ [PASS] ${cur_name} 升级成功！${COLOR_RESET}\n"
            success_count=$(( success_count + 1 ))
        else
            echo -e "  ${COLOR_RED}✘ [FAIL] ${cur_name} 升级失败，请检查网络或 SSH 权限${COLOR_RESET}\n"
            fail_count=$(( fail_count + 1 ))
            failed_nodes+=("${cur_name}")
        fi
        i=$(( i + 1 ))
    done

    echo -e "${COLOR_BOLD}================================================================================${COLOR_RESET}"
    echo -e "${COLOR_BOLD}                          批量升级执行汇总报告                                  ${COLOR_RESET}"
    echo -e "${COLOR_BOLD}================================================================================${COLOR_RESET}"
    echo -e "服务器总数: ${total}"
    echo -e "成功升级  : ${COLOR_GREEN}${success_count}${COLOR_RESET}"
    echo -e "失败机器  : ${COLOR_RED}${fail_count}${COLOR_RESET}"

    if [[ "${fail_count}" -gt 0 ]]; then
        echo -e "\n${COLOR_RED}以下节点升级失败: ${failed_nodes[*]}${COLOR_RESET}\n"
        return 1
    else
        echo -e "\n${COLOR_BOLD}${COLOR_GREEN}🎉 所有已注册服务器已 100% 成功升级至最新版本！${COLOR_RESET}\n"
        return 0
    fi
}

# ------------------------------------------------------------------------------
# 13. 交互式服务器切换菜单中心 (ops switch)
# ------------------------------------------------------------------------------
ops_node_switch() {
    _ops_node_ensure_file
    local active
    active=$(ops_node_get_active)

    # 读取节点列表到数组
    local node_names=("local")
    local node_targets=("127.0.0.1 (本机)")
    
    while IFS='|' read -r name target opts desc || [[ -n "${name}" ]]; do
        [[ -z "${name}" || "${name}" =~ ^# ]] && continue
        node_names+=("${name}")
        node_targets+=("${target}")
    done < "${OPS_NODES_FILE}"

    echo -e "${COLOR_BOLD}================================================================================${COLOR_RESET}"
    echo -e "${COLOR_BOLD}                 Ops-Monitor 服务器集群一键切换中心                             ${COLOR_RESET}"
    echo -e "${COLOR_BOLD}================================================================================${COLOR_RESET}"
    echo -e "  当前默认活动服务器: ${COLOR_GREEN}${active}${COLOR_RESET}\n"

    local total=${#node_names[@]}
    local i=0
    while [[ $i -lt $total ]]; do
        local n="${node_names[$i]}"
        local t="${node_targets[$i]}"
        local mark=""
        if [[ "${n}" == "${active}" ]]; then
            mark=" ${COLOR_GREEN}★ 当前活跃${COLOR_RESET}"
        fi
        printf "  [%d]  %-18s  %-30s %b\n" "$i" "${n}" "${t}" "${mark}"
        i=$(( i + 1 ))
    done

    echo ""
    echo "  [+]  添加注册新服务器"
    echo "  [u]  一键批量升级所有服务器 (Update All)"
    echo "  [i]  从 ~/.ssh/config 自动发现并批量导入"
    echo "  [q]  退出"
    echo -e "${COLOR_BOLD}================================================================================${COLOR_RESET}"

    read -r -p "👉 请输入序号选择服务器 (0-$(( total - 1 ))) 或功能键: " choice

    if [[ "${choice}" == "q" || "${choice}" == "Q" || -z "${choice}" ]]; then
        return 0
    elif [[ "${choice}" == "+" ]]; then
        echo ""
        read -r -p "请输入 SSH 连接串 (例如 root@1.2.3.4 -i ~/.ssh/id_rsa): " add_input
        if [[ -n "${add_input}" ]]; then
            ops_node_add "${add_input}"
        fi
        return 0
    elif [[ "${choice}" == "u" || "${choice}" == "U" ]]; then
        echo ""
        ops_node_update_all
        return 0
    elif [[ "${choice}" == "i" || "${choice}" == "I" ]]; then
        echo ""
        ops_node_import_ssh
        return 0
    elif [[ "${choice}" =~ ^[0-9]+$ ]] && [[ "${choice}" -lt "${total}" ]]; then
        local chosen_name="${node_names[$choice]}"
        local chosen_target="${node_targets[$choice]}"

        # 核心优化：直接完成服务器切换！
        ops_node_use "${chosen_name}"

        echo -e "\n已切换工作服务器为: ${COLOR_CYAN}${chosen_name}${COLOR_RESET} (${chosen_target})"
        echo "  [1] 打开实时性能动态看板 (Dashboard) [回车默认]"
        echo "  [2] 查看单次健康体检卡片 (Status)"
        echo "  [3] SSH 终端直连登录 (Connect)"
        echo "  [q] 完成切换，直接返回命令行"
        echo ""

        read -r -p "👉 请选择操作 (回车直接查看看板, q 返回终端): " act_choice || act_choice="1"
        [[ -z "${act_choice}" ]] && act_choice="1"

        case "${act_choice}" in
            1)
                ops_node_dashboard "${chosen_name}"
                ;;
            2)
                ops_node_status "${chosen_name}"
                ;;
            3)
                ops_node_connect "${chosen_name}"
                ;;
            *)
                echo -e "已切换默认服务器为 ${COLOR_GREEN}${chosen_name}${COLOR_RESET}。现在敲 ${COLOR_BOLD}ops status${COLOR_RESET} 将直接查看该服务器！\n"
                ;;
        esac
    else
        ops_log_err "输入无效"
    fi
}
