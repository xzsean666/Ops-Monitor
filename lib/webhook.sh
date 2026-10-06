#!/usr/bin/env bash
# ==============================================================================
# Ops-Monitor 多通道 Webhook 适配引擎 (lib/webhook.sh)
# 支持 Slack, 钉钉 (HMAC-SHA256 加签), 飞书, 企业微信
# 具备强网络超时控制与多通道并发/顺序广播
# ==============================================================================

_WEBHOOK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${_WEBHOOK_LIB_DIR}/common.sh"
# shellcheck source=config_mgr.sh
source "${_WEBHOOK_LIB_DIR}/config_mgr.sh"
unset _WEBHOOK_LIB_DIR

# 获取当前主机标识与 IP
_ops_get_hostname() {
    hostname -f 2>/dev/null || hostname 2>/dev/null || echo "Linux-Server"
}

_ops_get_host_ip() {
    local cache_file="${OPS_STATE_DATA_DIR:-/tmp}/.ops_cached_ip"
    if [[ -f "${cache_file}" ]]; then
        local cache_mtime now_ts
        cache_mtime=$(stat -c %Y "${cache_file}" 2>/dev/null || stat -f %m "${cache_file}" 2>/dev/null || echo 0)
        now_ts=$(date +%s)
        if (( now_ts - cache_mtime < 3600 )); then
            cat "${cache_file}"
            return 0
        fi
    fi

    local private_ip public_ip final_ip
    private_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
    [[ -z "${private_ip}" ]] && private_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -z "${private_ip}" ]] && private_ip="127.0.0.1"

    public_ip=$(curl -fsSL --connect-timeout 1 --max-time 2 https://api.ipify.org 2>/dev/null || curl -fsSL --connect-timeout 1 --max-time 2 https://ifconfig.me/ip 2>/dev/null || true)
    if [[ "${public_ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        if [[ "${public_ip}" != "${private_ip}" && -n "${private_ip}" && "${private_ip}" != "127.0.0.1" ]]; then
            final_ip="${public_ip} (${private_ip})"
        else
            final_ip="${public_ip}"
        fi
    else
        final_ip="${private_ip}"
    fi

    echo -n "${final_ip}" > "${cache_file}" 2>/dev/null || true
    echo "${final_ip}"
}

# ------------------------------------------------------------------------------
# 通用 HTTP POST 请求发送器 (带强超时约束)
# ------------------------------------------------------------------------------
_ops_http_post() {
    local url="$1"
    local json_data="$2"

    if [[ -z "${url}" ]] || [[ -z "${json_data}" ]]; then
        return "${OPS_EXIT_GENERAL}"
    fi

    local http_code
    http_code=$(curl --connect-timeout 3 --max-time 5 -s -o /dev/null -w "%{http_code}" \
        -H "Content-Type: application/json; charset=utf-8" \
        -d "${json_data}" \
        "${url}" 2>/dev/null || echo "000")

    if [[ "${http_code}" =~ ^2[0-9]{2}$ ]]; then
        return 0
    else
        ops_log_warn "Webhook 请求响应异常 (HTTP ${http_code}): ${url}"
        return "${OPS_EXIT_NET_ERR}"
    fi
}

# ------------------------------------------------------------------------------
# 1. 钉钉 (DingTalk) 签名适配 (HMAC-SHA256)
# ------------------------------------------------------------------------------
ops_webhook_sign_dingtalk() {
    local base_url="$1"
    local secret="$2"

    if [[ -z "${secret}" ]]; then
        echo "${base_url}"
        return 0
    fi

    local timestamp
    timestamp=$(date +%s)000
    local string_to_sign="${timestamp}\n${secret}"
    
    local sign
    sign=$(echo -ne "${string_to_sign}" | openssl dgst -sha256 -hmac "${secret}" -binary 2>/dev/null | base64 | tr -d '\r\n')
    
    # 纯 Bash / awk 实现 URL 编码 (+, /, =)
    local sign_enc
    sign_enc=$(awk -v s="${sign}" 'BEGIN {
        gsub(/\+/, "%2B", s);
        gsub(/\//, "%2F", s);
        gsub(/=/, "%3D", s);
        print s;
    }')

    local separator="&"
    if [[ "${base_url}" != *\?* ]]; then
        separator="?"
    fi

    echo "${base_url}${separator}timestamp=${timestamp}&sign=${sign_enc}"
}

ops_webhook_send_dingtalk() {
    local metric_name="$1"
    local current_val="$2"
    local threshold="$3"
    local timestamp_str="${4:-$(date '+%Y-%m-%d %H:%M:%S')}"
    local is_recovered="${5:-0}"
    local unit="${6:-%}"

    local url
    url=$(ops_config_get "WEBHOOK_DINGTALK_URL" "")
    local secret
    secret=$(ops_config_get "WEBHOOK_DINGTALK_SECRET" "")
    [[ -z "${url}" ]] && return 0

    local final_url
    final_url=$(ops_webhook_sign_dingtalk "${url}" "${secret}")
    local host ip_addr
    host=$(_ops_get_hostname)
    ip_addr=$(_ops_get_host_ip)

    local metric_display="${metric_name}"
    case "${metric_name}" in
        CPU|TEST_CPU) metric_display="CPU 使用率" ;;
        MEM) metric_display="内存 使用率" ;;
        DISK) metric_display="磁盘 使用率" ;;
        NET_RX) metric_display="网络入站流量 (RX)" ;;
        NET_TX) metric_display="网络出站流量 (TX)" ;;
    esac

    if [[ "${metric_name}" == NET* && "${unit}" == "%" ]]; then
        unit=" MB/s"
    fi

    local title text
    if [[ "${is_recovered}" == "1" ]]; then
        title="✅ [Ops-Monitor 恢复] 指标恢复正常"
        text="### ✅ [Ops-Monitor 恢复] 服务器指标恢复正常\n- **主机节点**: ${host}\n- **IP 地址**: ${ip_addr}\n- **恢复指标**: ${metric_display}\n- **当前数值**: <font color=\"#34a853\">${current_val}${unit}</font>\n- **告警阈值**: ${threshold}${unit}\n- **恢复时间**: ${timestamp_str}\n"
    else
        title="🚨 [Ops-Monitor 告警] 资源使用率超限"
        text="### 🚨 [Ops-Monitor 告警] 服务器资源超限\n- **主机节点**: ${host}\n- **IP 地址**: ${ip_addr}\n- **触发指标**: ${metric_display}\n- **当前数值**: <font color=\"#d93025\">${current_val}${unit}</font>\n- **告警阈值**: ${threshold}${unit}\n- **告警时间**: ${timestamp_str}\n"
    fi

    local payload
    payload=$(cat <<EOF
{
  "msgtype": "markdown",
  "markdown": {
    "title": "${title}",
    "text": "${text}"
  }
}
EOF
)
    _ops_http_post "${final_url}" "${payload}"
}

# ------------------------------------------------------------------------------
# 2. Slack 适配 (Attachments / Block Kit)
# ------------------------------------------------------------------------------
ops_webhook_send_slack() {
    local metric_name="$1"
    local current_val="$2"
    local threshold="$3"
    local timestamp_str="${4:-$(date '+%Y-%m-%d %H:%M:%S')}"
    local is_recovered="${5:-0}"
    local unit="${6:-%}"

    local url
    url=$(ops_config_get "WEBHOOK_SLACK_URL" "")
    [[ -z "${url}" ]] && return 0

    local host ip_addr
    host=$(_ops_get_hostname)
    ip_addr=$(_ops_get_host_ip)

    local metric_display="${metric_name}"
    case "${metric_name}" in
        CPU|TEST_CPU) metric_display="CPU 使用率" ;;
        MEM) metric_display="内存 使用率" ;;
        DISK) metric_display="磁盘 使用率" ;;
        NET_RX) metric_display="网络入站流量 (RX)" ;;
        NET_TX) metric_display="网络出站流量 (TX)" ;;
    esac

    if [[ "${metric_name}" == NET* && "${unit}" == "%" ]]; then
        unit=" MB/s"
    fi

    local color title
    if [[ "${is_recovered}" == "1" ]]; then
        color="#2eb886"
        title="✅ [Ops-Monitor 恢复] 指标恢复正常"
    else
        color="#e01e5a"
        title="🚨 [Ops-Monitor 告警] 服务器资源超限"
    fi

    local payload
    payload=$(cat <<EOF
{
  "attachments": [
    {
      "color": "${color}",
      "title": "${title}",
      "fields": [
        {"title": "主机节点", "value": "${host}", "short": true},
        {"title": "IP 地址", "value": "${ip_addr}", "short": true},
        {"title": "指标名称", "value": "${metric_display}", "short": true},
        {"title": "当前数值", "value": "${current_val}${unit}", "short": true},
        {"title": "告警阈值", "value": "${threshold}${unit}", "short": true},
        {"title": "发生时间", "value": "${timestamp_str}", "short": true}
      ],
      "footer": "Ops-Monitor Zero-Dependency Agent"
    }
  ]
}
EOF
)
    _ops_http_post "${url}" "${payload}"
}

# ------------------------------------------------------------------------------
# 3. 飞书 (Feishu) 适配 (Interactive Card)
# ------------------------------------------------------------------------------
ops_webhook_send_feishu() {
    local metric_name="$1"
    local current_val="$2"
    local threshold="$3"
    local timestamp_str="${4:-$(date '+%Y-%m-%d %H:%M:%S')}"
    local is_recovered="${5:-0}"
    local unit="${6:-%}"

    local url
    url=$(ops_config_get "WEBHOOK_FEISHU_URL" "")
    [[ -z "${url}" ]] && return 0

    local host ip_addr
    host=$(_ops_get_hostname)
    ip_addr=$(_ops_get_host_ip)

    local metric_display="${metric_name}"
    case "${metric_name}" in
        CPU|TEST_CPU) metric_display="CPU 使用率" ;;
        MEM) metric_display="内存 使用率" ;;
        DISK) metric_display="磁盘 使用率" ;;
        NET_RX) metric_display="网络入站流量 (RX)" ;;
        NET_TX) metric_display="网络出站流量 (TX)" ;;
    esac

    if [[ "${metric_name}" == NET* && "${unit}" == "%" ]]; then
        unit=" MB/s"
    fi

    local template title
    if [[ "${is_recovered}" == "1" ]]; then
        template="green"
        title="✅ [Ops-Monitor 恢复] 指标恢复正常"
    else
        template="red"
        title="🚨 [Ops-Monitor 告警] 服务器资源超限"
    fi

    local payload
    payload=$(cat <<EOF
{
  "msg_type": "interactive",
  "card": {
    "header": {
      "title": {"tag": "plain_text", "content": "${title}"},
      "template": "${template}"
    },
    "elements": [
      {
        "tag": "div",
        "text": {
          "tag": "lark_md",
          "content": "**主机节点**: ${host}\n**IP 地址**: ${ip_addr}\n**触发指标**: ${metric_display}\n**当前数值**: ${current_val}${unit}\n**告警阈值**: ${threshold}${unit}\n**发生时间**: ${timestamp_str}"
        }
      }
    ]
  }
}
EOF
)
    _ops_http_post "${url}" "${payload}"
}

# ------------------------------------------------------------------------------
# 4. 企业微信 (WeCom) 适配 (Markdown)
# ------------------------------------------------------------------------------
ops_webhook_send_wecom() {
    local metric_name="$1"
    local current_val="$2"
    local threshold="$3"
    local timestamp_str="${4:-$(date '+%Y-%m-%d %H:%M:%S')}"
    local is_recovered="${5:-0}"
    local unit="${6:-%}"

    local url
    url=$(ops_config_get "WEBHOOK_WECOM_URL" "")
    [[ -z "${url}" ]] && return 0

    local host ip_addr
    host=$(_ops_get_hostname)
    ip_addr=$(_ops_get_host_ip)

    local metric_display="${metric_name}"
    case "${metric_name}" in
        CPU|TEST_CPU) metric_display="CPU 使用率" ;;
        MEM) metric_display="内存 使用率" ;;
        DISK) metric_display="磁盘 使用率" ;;
        NET_RX) metric_display="网络入站流量 (RX)" ;;
        NET_TX) metric_display="网络出站流量 (TX)" ;;
    esac

    if [[ "${metric_name}" == NET* && "${unit}" == "%" ]]; then
        unit=" MB/s"
    fi

    local content
    if [[ "${is_recovered}" == "1" ]]; then
        content="### ✅ <font color=\"info\">[Ops-Monitor 恢复]</font> 指标恢复正常\n> **主机节点**: ${host}\n> **IP 地址**: ${ip_addr}\n> **恢复指标**: ${metric_display}\n> **当前数值**: <font color=\"info\">${current_val}${unit}</font>\n> **告警阈值**: ${threshold}${unit}\n> **恢复时间**: ${timestamp_str}"
    else
        content="### 🚨 <font color=\"warning\">[Ops-Monitor 告警]</font> 服务器资源超限\n> **主机节点**: ${host}\n> **IP 地址**: ${ip_addr}\n> **触发指标**: ${metric_display}\n> **当前数值**: <font color=\"warning\">${current_val}${unit}</font>\n> **告警阈值**: ${threshold}${unit}\n> **告警时间**: ${timestamp_str}"
    fi

    local payload
    payload=$(cat <<EOF
{
  "msgtype": "markdown",
  "markdown": {
    "content": "${content}"
  }
}
EOF
)
    _ops_http_post "${url}" "${payload}"
}

# ------------------------------------------------------------------------------
# 多通道联合广播
# ------------------------------------------------------------------------------
ops_webhook_broadcast() {
    local metric_name="$1"
    local current_val="$2"
    local threshold="$3"
    local timestamp_str="${4:-$(date '+%Y-%m-%d %H:%M:%S')}"
    local is_recovered="${5:-0}"

    ops_webhook_send_slack "$@" || true
    ops_webhook_send_dingtalk "$@" || true
    ops_webhook_send_feishu "$@" || true
    ops_webhook_send_wecom "$@" || true
    return 0
}

# ------------------------------------------------------------------------------
# 业务服务健康探测 Webhook 适配与多通道广播
# ------------------------------------------------------------------------------
ops_webhook_send_service_slack() {
    local service_name="$1"
    local probe_url="$2"
    local http_code="$3"
    local detail_msg="${4:-}"
    local is_recovered="${5:-0}"
    local restart_cmd="${6:-}"

    local url
    url=$(ops_config_get "WEBHOOK_SLACK_URL" "")
    [[ -z "${url}" ]] && return 0

    local host ip_addr
    host=$(_ops_get_hostname)
    ip_addr=$(_ops_get_host_ip)

    local color title
    if [[ "${is_recovered}" == "1" ]]; then
        color="#2eb886"
        title="✅ [Ops-Monitor 恢复] 业务服务已恢复健康"
    else
        color="#e01e5a"
        title="🚨 [Ops-Monitor 告警] 业务服务健康探测异常与自愈"
    fi

    local timestamp_str
    timestamp_str="$(date '+%Y-%m-%d %H:%M:%S')"

    local restart_display="未配置"
    [[ -n "${restart_cmd}" ]] && restart_display="\`${restart_cmd}\`"

    local payload
    payload=$(cat <<EOF
{
  "attachments": [
    {
      "color": "${color}",
      "title": "${title}",
      "fields": [
        {"title": "主机节点", "value": "${host}", "short": true},
        {"title": "IP 地址", "value": "${ip_addr}", "short": true},
        {"title": "服务名称", "value": "${service_name}", "short": true},
        {"title": "HTTP 状态", "value": "${http_code}", "short": true},
        {"title": "探测地址", "value": "${probe_url}", "short": false},
        {"title": "自愈动作", "value": "${restart_display}", "short": true},
        {"title": "发生时间", "value": "${timestamp_str}", "short": true},
        {"title": "诊断详情", "value": "${detail_msg}", "short": false}
      ],
      "footer": "Ops-Monitor Service Health Agent"
    }
  ]
}
EOF
)
    _ops_http_post "${url}" "${payload}"
}

ops_webhook_send_service_dingtalk() {
    local service_name="$1"
    local probe_url="$2"
    local http_code="$3"
    local detail_msg="${4:-}"
    local is_recovered="${5:-0}"
    local restart_cmd="${6:-}"

    local url
    url=$(ops_config_get "WEBHOOK_DINGTALK_URL" "")
    local secret
    secret=$(ops_config_get "WEBHOOK_DINGTALK_SECRET" "")
    [[ -z "${url}" ]] && return 0

    local final_url
    final_url=$(ops_webhook_sign_dingtalk "${url}" "${secret}")
    local host ip_addr
    host=$(_ops_get_hostname)
    ip_addr=$(_ops_get_host_ip)

    local title text timestamp_str
    timestamp_str="$(date '+%Y-%m-%d %H:%M:%S')"

    if [[ "${is_recovered}" == "1" ]]; then
        title="✅ [Ops-Monitor 恢复] 业务服务已恢复正常"
        text="### ✅ [Ops-Monitor 恢复] 业务服务已恢复正常\n- **主机节点**: ${host}\n- **IP 地址**: ${ip_addr}\n- **服务名称**: ${service_name}\n- **探测地址**: ${probe_url}\n- **HTTP 状态**: <font color=\"#34a853\">${http_code}</font>\n- **诊断详情**: ${detail_msg}\n- **恢复时间**: ${timestamp_str}\n"
    else
        title="🚨 [Ops-Monitor 告警] 业务服务健康探测异常与自愈"
        local restart_desc="无自愈动作"
        [[ -n "${restart_cmd}" ]] && restart_desc="执行: \`${restart_cmd}\`"
        text="### 🚨 [Ops-Monitor 告警] 业务服务健康探测异常\n- **主机节点**: ${host}\n- **IP 地址**: ${ip_addr}\n- **服务名称**: ${service_name}\n- **探测地址**: ${probe_url}\n- **HTTP 状态**: <font color=\"#d93025\">${http_code}</font>\n- **自愈机制**: ${restart_desc}\n- **诊断详情**: ${detail_msg}\n- **告警时间**: ${timestamp_str}\n"
    fi

    local payload
    payload=$(cat <<EOF
{
  "msgtype": "markdown",
  "markdown": {
    "title": "${title}",
    "text": "${text}"
  }
}
EOF
)
    _ops_http_post "${final_url}" "${payload}"
}

ops_webhook_send_service_feishu() {
    local service_name="$1"
    local probe_url="$2"
    local http_code="$3"
    local detail_msg="${4:-}"
    local is_recovered="${5:-0}"
    local restart_cmd="${6:-}"

    local url
    url=$(ops_config_get "WEBHOOK_FEISHU_URL" "")
    [[ -z "${url}" ]] && return 0

    local host ip_addr
    host=$(_ops_get_hostname)
    ip_addr=$(_ops_get_host_ip)

    local template title timestamp_str
    timestamp_str="$(date '+%Y-%m-%d %H:%M:%S')"

    if [[ "${is_recovered}" == "1" ]]; then
        template="green"
        title="✅ [Ops-Monitor 恢复] 业务服务已恢复健康"
    else
        template="red"
        title="🚨 [Ops-Monitor 告警] 业务服务健康探测异常与自愈"
    fi

    local restart_desc="未配置"
    [[ -n "${restart_cmd}" ]] && restart_desc="${restart_cmd}"

    local payload
    payload=$(cat <<EOF
{
  "msg_type": "interactive",
  "card": {
    "header": {
      "title": {"tag": "plain_text", "content": "${title}"},
      "template": "${template}"
    },
    "elements": [
      {
        "tag": "div",
        "text": {
          "tag": "lark_md",
          "content": "**主机节点**: ${host}\n**IP 地址**: ${ip_addr}\n**服务名称**: ${service_name}\n**HTTP 状态**: ${http_code}\n**探测地址**: ${probe_url}\n**自愈动作**: ${restart_desc}\n**发生时间**: ${timestamp_str}\n**诊断信息**: ${detail_msg}"
        }
      }
    ]
  }
}
EOF
)
    _ops_http_post "${url}" "${payload}"
}

ops_webhook_send_service_wecom() {
    local service_name="$1"
    local probe_url="$2"
    local http_code="$3"
    local detail_msg="${4:-}"
    local is_recovered="${5:-0}"
    local restart_cmd="${6:-}"

    local url
    url=$(ops_config_get "WEBHOOK_WECOM_URL" "")
    [[ -z "${url}" ]] && return 0

    local host ip_addr
    host=$(_ops_get_hostname)
    ip_addr=$(_ops_get_host_ip)

    local timestamp_str text
    timestamp_str="$(date '+%Y-%m-%d %H:%M:%S')"

    if [[ "${is_recovered}" == "1" ]]; then
        text="### ✅ [Ops-Monitor 恢复] 业务服务已恢复健康\n> **主机节点**: <font color=\"comment\">${host}</font>\n> **IP 地址**: <font color=\"comment\">${ip_addr}</font>\n> **服务名称**: <font color=\"info\">${service_name}</font>\n> **HTTP 状态**: <font color=\"info\">${http_code}</font>\n> **探测地址**: ${probe_url}\n> **诊断详情**: ${detail_msg}\n> **恢复时间**: ${timestamp_str}"
    else
        local restart_desc="未配置"
        [[ -n "${restart_cmd}" ]] && restart_desc="\`${restart_cmd}\`"
        text="### 🚨 [Ops-Monitor 告警] 业务服务健康探测异常与自愈\n> **主机节点**: <font color=\"comment\">${host}</font>\n> **IP 地址**: <font color=\"comment\">${ip_addr}</font>\n> **服务名称**: <font color=\"warning\">${service_name}</font>\n> **HTTP 状态**: <font color=\"warning\">${http_code}</font>\n> **探测地址**: ${probe_url}\n> **自愈动作**: ${restart_desc}\n> **诊断详情**: ${detail_msg}\n> **发生时间**: ${timestamp_str}"
    fi

    local payload
    payload=$(cat <<EOF
{
  "msgtype": "markdown",
  "markdown": {
    "content": "${text}"
  }
}
EOF
)
    _ops_http_post "${url}" "${payload}"
}

ops_webhook_broadcast_service() {
    ops_webhook_send_service_slack "$@" || true
    ops_webhook_send_service_dingtalk "$@" || true
    ops_webhook_send_service_feishu "$@" || true
    ops_webhook_send_service_wecom "$@" || true
    return 0
}

# ------------------------------------------------------------------------------
# 连通性测试命令 (ops config test-alert)
# ------------------------------------------------------------------------------
ops_webhook_test_alert() {
    local host
    host=$(_ops_get_hostname)
    local now
    now=$(date '+%Y-%m-%d %H:%M:%S')
    
    local any_configured=0
    local slack_url ding_url feishu_url wecom_url
    slack_url=$(ops_config_get "WEBHOOK_SLACK_URL" "")
    ding_url=$(ops_config_get "WEBHOOK_DINGTALK_URL" "")
    feishu_url=$(ops_config_get "WEBHOOK_FEISHU_URL" "")
    wecom_url=$(ops_config_get "WEBHOOK_WECOM_URL" "")

    ops_log_info "正在向已配置的 Webhook 通道发送测试告警卡片..."

    if [[ -n "${slack_url}" ]]; then
        any_configured=1
        if ops_webhook_send_slack "TEST_CPU" "99.9" "85.0" "${now}" 0; then
            ops_log_info "  [Slack] 发送测试消息成功"
        else
            ops_log_err "  [Slack] 发送测试消息失败"
        fi
    fi

    if [[ -n "${ding_url}" ]]; then
        any_configured=1
        if ops_webhook_send_dingtalk "TEST_CPU" "99.9" "85.0" "${now}" 0; then
            ops_log_info "  [DingTalk] 发送测试消息成功"
        else
            ops_log_err "  [DingTalk] 发送测试消息失败"
        fi
    fi

    if [[ -n "${feishu_url}" ]]; then
        any_configured=1
        if ops_webhook_send_feishu "TEST_CPU" "99.9" "85.0" "${now}" 0; then
            ops_log_info "  [Feishu] 发送测试消息成功"
        else
            ops_log_err "  [Feishu] 发送测试消息失败"
        fi
    fi

    if [[ -n "${wecom_url}" ]]; then
        any_configured=1
        if ops_webhook_send_wecom "TEST_CPU" "99.9" "85.0" "${now}" 0; then
            ops_log_info "  [WeCom] 发送测试消息成功"
        else
            ops_log_err "  [WeCom] 发送测试消息失败"
        fi
    fi

    if [[ "${any_configured}" -eq 0 ]]; then
        ops_log_warn "未配置任何 Webhook URL (WEBHOOK_SLACK_URL, WEBHOOK_DINGTALK_URL, WEBHOOK_FEISHU_URL, WEBHOOK_WECOM_URL)"
        return 0
    fi
}
