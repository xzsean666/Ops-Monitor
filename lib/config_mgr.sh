#!/usr/bin/env bash
# ==============================================================================
# Ops-Monitor 配置管理引擎 (lib/config_mgr.sh)
# 负责配置加载优先级、参数校验、CRUD、权限加固与安全 Base64 导入导出
# ==============================================================================

# 引入公共库
_CONFIG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${_CONFIG_LIB_DIR}/common.sh"
unset _CONFIG_LIB_DIR

# 避免重复初始化全局关联数组
if [[ -z "${OPS_CONF+exists}" ]]; then
    declare -g -A OPS_CONF=()
fi

# 允许配置项白名单定义
OPS_VALID_CONFIG_KEYS=(
    "COLLECT_INTERVAL"
    "RETENTION_DAYS"
    "ARCHIVE_DIR"
    "ALERT_CPU_THRESHOLD"
    "ALERT_CPU_CONSECUTIVE"
    "ALERT_MEM_THRESHOLD"
    "ALERT_DISK_THRESHOLD"
    "ALERT_NET_RX_THRESHOLD_MB"
    "ALERT_NET_TX_THRESHOLD_MB"
    "ALERT_NET_CONSECUTIVE"
    "ALERT_COOLDOWN_MINUTES"
    "WEBHOOK_SLACK_URL"
    "WEBHOOK_DINGTALK_URL"
    "WEBHOOK_DINGTALK_SECRET"
    "WEBHOOK_FEISHU_URL"
    "WEBHOOK_WECOM_URL"
)

# ------------------------------------------------------------------------------
# 键与值合法性校验
# ------------------------------------------------------------------------------
ops_config_is_valid_key() {
    local key="$1"
    local k
    for k in "${OPS_VALID_CONFIG_KEYS[@]}"; do
        if [[ "${k}" == "${key}" ]]; then
            return 0
        fi
    done
    return 1
}

ops_config_validate_val() {
    local key="$1"
    local val="$2"

    # 防注入检查：禁止换行符与不可打印字符
    if [[ "${val}" =~ [$'\r\n'] ]]; then
        ops_log_err "配置值包含非法换行字符: ${key}"
        return 1
    fi

    case "${key}" in
        COLLECT_INTERVAL)
            if ! [[ "${val}" =~ ^[0-9]+$ ]] || [[ "${val}" -lt 1 ]]; then
                ops_log_err "COLLECT_INTERVAL 必须为大于等于 1 的正整数 (当前: '${val}')"
                return 1
            fi
            ;;
        RETENTION_DAYS)
            if ! [[ "${val}" =~ ^[0-9]+$ ]] || [[ "${val}" -lt 1 ]]; then
                ops_log_err "RETENTION_DAYS 必须为大于等于 1 的正整数 (当前: '${val}')"
                return 1
            fi
            ;;
        ARCHIVE_DIR)
            # 允许为空；若非空则必须为绝对路径且不包含非法特殊字符
            if [[ -n "${val}" ]]; then
                if [[ "${val}" =~ [\"\`\$\;\|\&\<\>] ]]; then
                    ops_log_err "ARCHIVE_DIR 包含非法字符: '${val}'"
                    return 1
                fi
            fi
            ;;
        ALERT_CPU_THRESHOLD|ALERT_MEM_THRESHOLD|ALERT_DISK_THRESHOLD)
            if ! [[ "${val}" =~ ^[0-9]+$ ]] || [[ "${val}" -lt 1 ]] || [[ "${val}" -gt 100 ]]; then
                ops_log_err "${key} 必须在 1 到 100 之间 (当前: '${val}')"
                return 1
            fi
            ;;
        ALERT_CPU_CONSECUTIVE)
            if ! [[ "${val}" =~ ^[0-9]+$ ]] || [[ "${val}" -lt 1 ]]; then
                ops_log_err "ALERT_CPU_CONSECUTIVE 必须为大于等于 1 的整数 (当前: '${val}')"
                return 1
            fi
            ;;
        ALERT_NET_RX_THRESHOLD_MB|ALERT_NET_TX_THRESHOLD_MB)
            if ! [[ "${val}" =~ ^[0-9]+$ ]] || [[ "${val}" -lt 0 ]]; then
                ops_log_err "${key} 必须为大于等于 0 的整数 (单位 MB/s，0 为关闭告警，当前: '${val}')"
                return 1
            fi
            ;;
        ALERT_NET_CONSECUTIVE)
            if ! [[ "${val}" =~ ^[0-9]+$ ]] || [[ "${val}" -lt 1 ]]; then
                ops_log_err "ALERT_NET_CONSECUTIVE 必须为大于等于 1 的整数 (当前: '${val}')"
                return 1
            fi
            ;;
        ALERT_COOLDOWN_MINUTES)
            if ! [[ "${val}" =~ ^[0-9]+$ ]] || [[ "${val}" -lt 0 ]]; then
                ops_log_err "ALERT_COOLDOWN_MINUTES 必须为大于等于 0 的整数 (当前: '${val}')"
                return 1
            fi
            ;;
        WEBHOOK_SLACK_URL|WEBHOOK_DINGTALK_URL|WEBHOOK_FEISHU_URL|WEBHOOK_WECOM_URL)
            if [[ -n "${val}" ]]; then
                if ! [[ "${val}" =~ ^https?:// ]]; then
                    ops_log_err "${key} 必须以 http:// 或 https:// 开头 (当前: '${val}')"
                    return 1
                fi
                if [[ "${val}" =~ [\"\'\`\$\;\|\<\>] ]]; then
                    ops_log_err "${key} 包含非法 URL 字符"
                    return 1
                fi
            fi
            ;;
        WEBHOOK_DINGTALK_SECRET)
            if [[ -n "${val}" ]] && [[ "${val}" =~ [\"\'\`\$\;\|\<\>] ]]; then
                ops_log_err "WEBHOOK_DINGTALK_SECRET 包含非法字符"
                return 1
            fi
            ;;
        *)
            ops_log_err "未知配置键: ${key}"
            return 1
            ;;
    esac
    return 0
}

# ------------------------------------------------------------------------------
# 配置文件优先级解析与定位
# 优先级: 指定文件 > ~/.ops.conf > /etc/ops-monitor/ops.conf > $CONFIG_DIR/ops.conf > 本地 config/ops.conf > 默认模版
# ------------------------------------------------------------------------------
ops_config_resolve_read_file() {
    if [[ -n "${OPS_CONFIG_FILE:-}" ]] && [[ -f "${OPS_CONFIG_FILE}" ]]; then
        echo "${OPS_CONFIG_FILE}"
        return 0
    fi

    # 用户主目录覆盖
    if [[ -f "$HOME/.ops.conf" ]]; then
        echo "$HOME/.ops.conf"
        return 0
    fi

    # 全局 /etc 配置文件
    if [[ -f "/etc/ops-monitor/ops.conf" ]]; then
        echo "/etc/ops-monitor/ops.conf"
        return 0
    fi

    # 用户或系统标准 CONFIG_DIR 配置文件
    if [[ -f "${OPS_CONFIG_DIR}/ops.conf" ]]; then
        echo "${OPS_CONFIG_DIR}/ops.conf"
        return 0
    fi

    # 项目本地 config/ops.conf
    if [[ -f "${OPS_LOCAL_CONFIG}" ]]; then
        echo "${OPS_LOCAL_CONFIG}"
        return 0
    fi

    # 回退到默认出厂配置模版
    if [[ -f "${OPS_TEMPLATE_CONFIG}" ]]; then
        echo "${OPS_TEMPLATE_CONFIG}"
        return 0
    fi

    return 1
}

ops_config_resolve_write_file() {
    if [[ -n "${OPS_CONFIG_FILE:-}" ]]; then
        echo "${OPS_CONFIG_FILE}"
        return 0
    fi

    if [[ "${OPS_UID}" -eq 0 ]]; then
        echo "/etc/ops-monitor/ops.conf"
    else
        if [[ -f "$HOME/.ops.conf" ]]; then
            echo "$HOME/.ops.conf"
        else
            echo "${OPS_CONFIG_DIR}/ops.conf"
        fi
    fi
}

# ------------------------------------------------------------------------------
# 安全逐行加载配置 (严格杜绝 eval)
# ------------------------------------------------------------------------------
_ops_config_parse_file() {
    local target="$1"
    [[ ! -f "${target}" ]] && return 0

    while IFS= read -r line || [[ -n "${line}" ]]; do
        # 去除两端空白字符
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"

        # 忽略空行和注释行
        [[ -z "${line}" || "${line}" =~ ^# ]] && continue

        # 提取 KEY 与 VALUE
        if [[ "${line}" =~ ^([A-Za-z0-9_]+)=(.*)$ ]]; then
            local k="${BASH_REMATCH[1]}"
            local v="${BASH_REMATCH[2]}"

            # 去除可能包含的行尾注释 (例如: VAL # 注释)
            # 但若值本身被引号包围则保留引号内内容
            if [[ "${v}" =~ ^\"(.*)\"[[:space:]]*(#.*)?$ ]]; then
                v="${BASH_REMATCH[1]}"
            elif [[ "${v}" =~ ^\'(.*)\'[[:space:]]*(#.*)?$ ]]; then
                v="${BASH_REMATCH[1]}"
            elif [[ "${v}" =~ ^([^#[:space:]]+)[[:space:]]*(#.*)?$ ]]; then
                v="${BASH_REMATCH[1]}"
            fi

            # 白名单与合法性检查
            if ops_config_is_valid_key "${k}"; then
                OPS_CONF["${k}"]="${v}"
            fi
        fi
    done < "${target}"
}

ops_config_load() {
    local custom_file="${1:-}"
    
    # 1. 先加载出厂默认值作为基底
    if [[ -f "${OPS_TEMPLATE_CONFIG}" ]]; then
        _ops_config_parse_file "${OPS_TEMPLATE_CONFIG}"
    fi

    # 2. 查找并叠加生效的配置文件
    local active_file
    if [[ -n "${custom_file}" ]] && [[ -f "${custom_file}" ]]; then
        active_file="${custom_file}"
    else
        active_file=$(ops_config_resolve_read_file || echo "")
    fi

    if [[ -n "${active_file}" ]] && [[ -f "${active_file}" ]]; then
        _ops_config_parse_file "${active_file}"
        # 若是正式配置文件，检查并加固权限
        if [[ "${active_file}" != "${OPS_TEMPLATE_CONFIG}" ]]; then
            ops_secure_file "${active_file}"
        fi
    fi
    return 0
}

# ------------------------------------------------------------------------------
# 配置读取与修改 (CRUD)
# ------------------------------------------------------------------------------
ops_config_get() {
    local key="$1"
    local default_val="${2:-}"

    if [[ ${#OPS_CONF[@]} -eq 0 ]]; then
        ops_config_load
    fi

    if [[ -n "${OPS_CONF[${key}]+exists}" ]]; then
        echo "${OPS_CONF[${key}]}"
    else
        echo "${default_val}"
    fi
}

ops_config_set() {
    local key="$1"
    local val="$2"
    local target_file="${3:-}"

    if ! ops_config_is_valid_key "${key}"; then
        ops_log_err "设置失败: 未知配置键 '${key}'"
        return "${OPS_EXIT_CONFIG_ERR}"
    fi

    if ! ops_config_validate_val "${key}" "${val}"; then
        return "${OPS_EXIT_CONFIG_ERR}"
    fi

    if [[ -z "${target_file}" ]]; then
        target_file=$(ops_config_resolve_write_file)
    fi

    local target_dir
    target_dir="$(dirname "${target_file}")"
    if [[ ! -d "${target_dir}" ]]; then
        mkdir -p "${target_dir}" 2>/dev/null || {
            ops_log_err "无法创建配置目录: ${target_dir}"
            return "${OPS_EXIT_PERM_ERR}"
        }
    fi

    # 若目标文件不存在，从模板拷贝或初始化
    if [[ ! -f "${target_file}" ]]; then
        if [[ -f "${OPS_TEMPLATE_CONFIG}" ]]; then
            cp "${OPS_TEMPLATE_CONFIG}" "${target_file}" 2>/dev/null || touch "${target_file}"
        else
            touch "${target_file}"
        fi
    fi

    # 原子安全替换键值
    local tmp_file="${target_file}.tmp.$$"
    local key_updated=0

    while IFS= read -r line || [[ -n "${line}" ]]; do
        if [[ "${line}" =~ ^[[:space:]]*${key}=.*$ ]]; then
            # 保持双引号包装格式
            echo "${key}=\"${val}\"" >> "${tmp_file}"
            key_updated=1
        else
            echo "${line}" >> "${tmp_file}"
        fi
    done < "${target_file}"

    if [[ "${key_updated}" -eq 0 ]]; then
        echo "${key}=\"${val}\"" >> "${tmp_file}"
    fi

    mv -f "${tmp_file}" "${target_file}"
    ops_secure_file "${target_file}"

    # 更新当前内存缓存
    OPS_CONF["${key}"]="${val}"
    ops_log_info "已更新配置: ${key}=${val} -> ${target_file}"
    return 0
}

# ------------------------------------------------------------------------------
# 配置列表与敏感信息脱敏展示
# ------------------------------------------------------------------------------
ops_config_mask_secret() {
    local str="$1"
    local len=${#str}
    if [[ "${len}" -le 6 ]]; then
        echo "******"
    else
        local prefix="${str:0:3}"
        local suffix="${str: -3}"
        echo "${prefix}******${suffix}"
    fi
}

ops_config_list() {
    local raw="${1:-0}"
    if [[ ${#OPS_CONF[@]} -eq 0 ]]; then
        ops_config_load
    fi

    local k v
    for k in "${OPS_VALID_CONFIG_KEYS[@]}"; do
        v="${OPS_CONF[${k}]:-}"
        if [[ "${raw}" != "1" ]]; then
            if [[ "${k}" =~ SECRET ]] && [[ -n "${v}" ]]; then
                v=$(ops_config_mask_secret "${v}")
            elif [[ "${k}" =~ URL ]] && [[ -n "${v}" ]]; then
                # Webhook URL 掩码 token 部分
                if [[ "${v}" =~ ^(https?://[^/]+/[^?]+)(\?.*)?$ ]]; then
                    local base="${BASH_REMATCH[1]}"
                    local q="${BASH_REMATCH[2]}"
                    if [[ -n "${q}" ]]; then
                        v="${base}?[PROTECTED]"
                    fi
                fi
            fi
        fi
        printf "%-25s = %s\n" "${k}" "${v}"
    done
}

# ------------------------------------------------------------------------------
# 安全 Base64 导出与导入引擎
# ------------------------------------------------------------------------------
ops_config_export() {
    local format="${1:-plain}" # plain, base64, template
    local output_file="${2:-}"

    if [[ ${#OPS_CONF[@]} -eq 0 ]]; then
        ops_config_load
    fi

    local buffer=""
    local k v
    for k in "${OPS_VALID_CONFIG_KEYS[@]}"; do
        v="${OPS_CONF[${k}]:-}"
        buffer+="${k}=\"${v}\""$'\n'
    done

    local output_text=""
    case "${format}" in
        base64)
            output_text=$(echo -n "${buffer}" | base64 | tr -d '\r\n')
            ;;
        template)
            if [[ -f "${OPS_TEMPLATE_CONFIG}" ]]; then
                output_text=$(cat "${OPS_TEMPLATE_CONFIG}")
            else
                output_text="${buffer}"
            fi
            ;;
        plain|*)
            output_text="${buffer}"
            ;;
    esac

    if [[ -n "${output_file}" ]]; then
        echo "${output_text}" > "${output_file}"
        ops_secure_file "${output_file}"
        ops_log_info "配置已导出至: ${output_file}"
    else
        echo "${output_text}"
    fi
}

ops_config_import() {
    local source_type="${1:-base64}" # base64, file, stdin
    local input_data="${2:-}"
    local target_file="${3:-}"

    if [[ -z "${target_file}" ]]; then
        target_file=$(ops_config_resolve_write_file)
    fi

    local raw_content=""
    case "${source_type}" in
        base64)
            if [[ -z "${input_data}" ]]; then
                ops_log_err "导入失败: 提供的 Base64 字符串为空"
                return "${OPS_EXIT_CONFIG_ERR}"
            fi
            raw_content=$(echo -n "${input_data}" | base64 -d 2>/dev/null) || {
                ops_log_err "导入失败: Base64 解码失败"
                return "${OPS_EXIT_CONFIG_ERR}"
            }
            ;;
        file)
            if [[ ! -f "${input_data}" ]]; then
                ops_log_err "导入失败: 文件不存在 '${input_data}'"
                return "${OPS_EXIT_CONFIG_ERR}"
            fi
            raw_content=$(cat "${input_data}")
            ;;
        stdin)
            raw_content=$(cat)
            ;;
        *)
            ops_log_err "不支持的导入源类型: ${source_type}"
            return "${OPS_EXIT_CONFIG_ERR}"
            ;;
    esac

    # 预解析并严格校验所有配置行
    local valid_lines=()
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "${line}" || "${line}" =~ ^# ]] && continue

        if [[ "${line}" =~ ^([A-Za-z0-9_]+)=(.*)$ ]]; then
            local k="${BASH_REMATCH[1]}"
            local v="${BASH_REMATCH[2]}"

            if [[ "${v}" =~ ^\"(.*)\"$ ]] || [[ "${v}" =~ ^\'(.*)\'$ ]]; then
                v="${BASH_REMATCH[1]}"
            fi

            if ! ops_config_is_valid_key "${k}"; then
                ops_log_err "导入拒绝: 包含非法配置键 '${k}'"
                return "${OPS_EXIT_CONFIG_ERR}"
            fi

            if ! ops_config_validate_val "${k}" "${v}"; then
                ops_log_err "导入拒绝: 配置项 '${k}' 的值不合法"
                return "${OPS_EXIT_CONFIG_ERR}"
            fi

            valid_lines+=("${k}=\"${v}\"")
        else
            ops_log_err "导入拒绝: 包含格式错误的行: '${line}'"
            return "${OPS_EXIT_CONFIG_ERR}"
        fi
    done <<< "${raw_content}"

    if [[ ${#valid_lines[@]} -eq 0 ]]; then
        ops_log_err "导入失败: 未解析到任何有效配置项"
        return "${OPS_EXIT_CONFIG_ERR}"
    fi

    # 原子写入目标文件
    local target_dir
    target_dir="$(dirname "${target_file}")"
    mkdir -p "${target_dir}" 2>/dev/null || true

    local tmp_file="${target_file}.import.$$"
    {
        echo "# Ops-Monitor 配置 (导入于 $(date '+%Y-%m-%d %H:%M:%S'))"
        for l in "${valid_lines[@]}"; do
            echo "${l}"
        done
    } > "${tmp_file}"

    mv -f "${tmp_file}" "${target_file}"
    ops_secure_file "${target_file}"

    # 重新加载并更新状态
    ops_config_load "${target_file}"
    ops_log_info "配置成功导入并已生效: ${target_file}"
    return 0
}
