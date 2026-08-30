#!/usr/bin/env bash
# ==============================================================================
# Ops-Monitor 公共基础库 (lib/common.sh)
# 提供路径推导、用户自适应、终端颜色、规范化日志、文件锁与权限沙箱支持
# ==============================================================================

# 避免重复 source
if [[ -n "${_OPS_COMMON_SH_LOADED:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi
_OPS_COMMON_SH_LOADED=1

# 版本号定义
OPS_VERSION="1.0.0"

# 项目根路径推导 (无论从何处执行或软链接调用均可准确解析)
if [[ -z "${OPS_BASE_DIR:-}" ]]; then
    _SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    OPS_BASE_DIR="$(cd "${_SRC_DIR}/.." && pwd)"
    unset _SRC_DIR
fi

# 退出码定义
OPS_EXIT_OK=0
OPS_EXIT_GENERAL=1
OPS_EXIT_CONFIG_ERR=2
OPS_EXIT_LOCK_ERR=3
OPS_EXIT_PERM_ERR=4
OPS_EXIT_NET_ERR=5

# 用户权限与自适应路径规划
OPS_UID="${EUID:-$(id -u 2>/dev/null || echo 1000)}"

if [[ "${OPS_UID}" -eq 0 ]]; then
    # Root 用户运行路径
    OPS_DEFAULT_CONFIG_DIR="/etc/ops-monitor"
    OPS_DEFAULT_CONFIG_FILE="/etc/ops-monitor/ops.conf"
    OPS_DEFAULT_DATA_DIR="/var/log/ops-monitor"
    OPS_DEFAULT_RUN_DIR="/var/run/ops-monitor"
    OPS_DEFAULT_LOCK_FILE="/var/run/ops-monitor.lock"
else
    # 非 Root 用户降级运行路径
    OPS_DEFAULT_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/ops-monitor"
    OPS_DEFAULT_CONFIG_FILE="${OPS_DEFAULT_CONFIG_DIR}/ops.conf"
    OPS_DEFAULT_DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/ops-monitor"
    OPS_DEFAULT_RUN_DIR="${XDG_RUNTIME_DIR:-/tmp}/ops-monitor-${OPS_UID}"
    OPS_DEFAULT_LOCK_FILE="${OPS_DEFAULT_RUN_DIR}/ops-monitor.lock"
fi

# 实际生效路径变量 (支持环境变量覆盖)
OPS_CONFIG_DIR="${OPS_CONFIG_DIR:-$OPS_DEFAULT_CONFIG_DIR}"
OPS_CONFIG_FILE="${OPS_CONFIG_FILE:-}" # 若为空由 config_mgr.sh 决策加载链
OPS_DATA_DIR="${OPS_DATA_DIR:-$OPS_DEFAULT_DATA_DIR}"
OPS_CURRENT_DATA_DIR="${OPS_DATA_DIR}/current"
OPS_STATE_DATA_DIR="${OPS_DATA_DIR}/state"
OPS_RUN_DIR="${OPS_RUN_DIR:-$OPS_DEFAULT_RUN_DIR}"
OPS_LOCK_FILE="${OPS_LOCK_FILE:-$OPS_DEFAULT_LOCK_FILE}"

# 模版与出厂配置路径
OPS_TEMPLATE_CONFIG="${OPS_BASE_DIR}/config/ops.conf.default"
OPS_LOCAL_CONFIG="${OPS_BASE_DIR}/config/ops.conf"

# ------------------------------------------------------------------------------
# 终端颜色与格式化常量
# ------------------------------------------------------------------------------
ops_init_colors() {
    local force="${1:-0}"
    if [[ "${force}" == "1" ]] || [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
        COLOR_RESET=$'\e[0m'
        COLOR_BOLD=$'\e[1m'
        COLOR_DIM=$'\e[2m'
        COLOR_UNDERLINE=$'\e[4m'
        
        COLOR_RED=$'\e[31m'
        COLOR_GREEN=$'\e[32m'
        COLOR_YELLOW=$'\e[33m'
        COLOR_BLUE=$'\e[34m'
        COLOR_MAGENTA=$'\e[35m'
        COLOR_CYAN=$'\e[36m'
        COLOR_WHITE=$'\e[37m'
        COLOR_GRAY=$'\e[90m'

        COLOR_BG_RED=$'\e[41m'
        COLOR_BG_GREEN=$'\e[42m'
        COLOR_BG_YELLOW=$'\e[43m'
        COLOR_BG_BLUE=$'\e[44m'
    else
        COLOR_RESET=""
        COLOR_BOLD=""
        COLOR_DIM=""
        COLOR_UNDERLINE=""
        
        COLOR_RED=""
        COLOR_GREEN=""
        COLOR_YELLOW=""
        COLOR_BLUE=""
        COLOR_MAGENTA=""
        COLOR_CYAN=""
        COLOR_WHITE=""
        COLOR_GRAY=""

        COLOR_BG_RED=""
        COLOR_BG_GREEN=""
        COLOR_BG_YELLOW=""
        COLOR_BG_BLUE=""
    fi
}
ops_init_colors 0

# ------------------------------------------------------------------------------
# 规范化日志输出与主机名获取
# ------------------------------------------------------------------------------
_ops_get_hostname() {
    hostname -f 2>/dev/null || hostname 2>/dev/null || echo "Linux-Server"
}

_ops_timestamp() {
    date "+%Y-%m-%d %H:%M:%S"
}

ops_log_info() {
    echo -e "${COLOR_GREEN}[$(_ops_timestamp)] [INFO]${COLOR_RESET} $*" >&2
}

ops_log_warn() {
    echo -e "${COLOR_YELLOW}[$(_ops_timestamp)] [WARN]${COLOR_RESET} $*" >&2
}

ops_log_err() {
    echo -e "${COLOR_RED}[$(_ops_timestamp)] [ERROR]${COLOR_RESET} $*" >&2
}

ops_log_debug() {
    if [[ "${OPS_DEBUG:-0}" == "1" ]]; then
        echo -e "${COLOR_GRAY}[$(_ops_timestamp)] [DEBUG]${COLOR_RESET} $*" >&2
    fi
}

# ------------------------------------------------------------------------------
# 运行目录与权限保障
# ------------------------------------------------------------------------------
ops_ensure_dirs() {
    local d
    for d in "${OPS_CURRENT_DATA_DIR}" "${OPS_STATE_DATA_DIR}" "${OPS_RUN_DIR}"; do
        if [[ ! -d "${d}" ]]; then
            mkdir -p "${d}" 2>/dev/null || {
                ops_log_err "无法创建目录: ${d} (权限不足)"
                return "${OPS_EXIT_PERM_ERR}"
            }
        fi
    done
    return 0
}

ops_secure_file() {
    local target="$1"
    if [[ -f "${target}" ]]; then
        chmod 0600 "${target}" 2>/dev/null || true
    fi
}

# 检查文件权限是否为 0600 或更严格 (不允许 group/others 读写)
ops_check_file_permission() {
    local target="$1"
    [[ ! -f "${target}" ]] && return 0
    
    local perm=""
    if stat --version >/dev/null 2>&1; then
        perm=$(stat -c "%a" "${target}" 2>/dev/null || echo "")
    else
        perm=$(stat -f "%OLp" "${target}" 2>/dev/null || echo "")
    fi

    # 若末两位不为 00 (如 644, 755)，视为权限过宽
    if [[ -n "${perm}" ]] && [[ "${perm}" =~ [0-9]*[1-7][1-7]$|[0-9]*0[1-7]$|[0-9]*[1-7]0$ ]]; then
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# flock 文件排他锁机制 (fd 200)
# ------------------------------------------------------------------------------
ops_lock_acquire() {
    local timeout="${1:-0}" # 0 表示非阻塞立即返回
    local lock_dir
    lock_dir="$(dirname "${OPS_LOCK_FILE}")"
    
    if [[ ! -d "${lock_dir}" ]]; then
        mkdir -p "${lock_dir}" 2>/dev/null || true
    fi

    # 打开 fd 200
    exec 200>"${OPS_LOCK_FILE}" 2>/dev/null || {
        ops_log_err "无法打开锁文件: ${OPS_LOCK_FILE}"
        return "${OPS_EXIT_LOCK_ERR}"
    }

    if [[ "${timeout}" -gt 0 ]]; then
        if ! flock -w "${timeout}" 200 2>/dev/null; then
            ops_log_warn "获取文件锁超时 (${timeout}s): ${OPS_LOCK_FILE}"
            return "${OPS_EXIT_LOCK_ERR}"
        fi
    else
        if ! flock -n 200 2>/dev/null; then
            ops_log_warn "资源已被其他进程锁定，跳过执行: ${OPS_LOCK_FILE}"
            return "${OPS_EXIT_LOCK_ERR}"
        fi
    fi
    return 0
}

ops_lock_release() {
    flock -u 200 2>/dev/null || true
    exec 200>&- 2>/dev/null || true
    return 0
}
