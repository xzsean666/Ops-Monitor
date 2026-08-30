#!/usr/bin/env bash
# ==============================================================================
# Ops-Monitor 指标采集引擎 (lib/collector.sh)
# 直接解析 procfs (/proc/stat, /proc/meminfo, /proc/net/dev) 与 df
# 零外部依赖、极低资源开销 (< 50ms)
# ==============================================================================

_COLLECTOR_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${_COLLECTOR_LIB_DIR}/common.sh"
# shellcheck source=config_mgr.sh
source "${_COLLECTOR_LIB_DIR}/config_mgr.sh"
unset _COLLECTOR_LIB_DIR

# 支持 Mock procfs 根路径覆盖
OPS_PROC_ROOT="${OPS_PROC_ROOT:-/proc}"

# ------------------------------------------------------------------------------
# 1. CPU 使用率计算 (procfs /proc/stat)
# ------------------------------------------------------------------------------
_ops_read_cpu_stat() {
    local stat_file="${OPS_PROC_ROOT}/stat"
    if [[ ! -f "${stat_file}" ]]; then
        echo "0 0"
        return 1
    fi

    # 读取第一行 cpu  user nice system idle iowait irq softirq steal guest guest_nice
    awk '
    /^cpu / {
        u = $2; n = $3; s = $4; idl = $5; iow = $6;
        irq = $7; sirq = $8; stl = $9;
        
        total = u + n + s + idl + iow + irq + sirq + stl;
        idle_all = idl + iow;
        print total, idle_all;
        exit;
    }
    ' "${stat_file}"
}

ops_collect_cpu() {
    local sample_interval="${1:-1}"
    
    local stat1 stat2
    stat1=$(_ops_read_cpu_stat)
    
    if [[ -z "${stat1}" ]]; then
        echo "0.0"
        return 0
    fi

    # 若指定了采样间隔则 sleep 后采第二点；若为 0 则直接返回 0.0 (单点瞬时)
    if (( $(echo "${sample_interval} > 0" | awk '{print ($1 > 0)}') )); then
        sleep "${sample_interval}"
        stat2=$(_ops_read_cpu_stat)
    else
        echo "0.0"
        return 0
    fi

    awk -v s1="${stat1}" -v s2="${stat2}" '
    BEGIN {
        split(s1, a1, " ");
        split(s2, a2, " ");
        total_diff = a2[1] - a1[1];
        idle_diff  = a2[2] - a1[2];
        if (total_diff <= 0) {
            printf "0.0\n";
        } else {
            usage = (1.0 - (idle_diff / total_diff)) * 100.0;
            if (usage < 0.0) usage = 0.0;
            if (usage > 100.0) usage = 100.0;
            printf "%.1f\n", usage;
        }
    }
    '
}

# ------------------------------------------------------------------------------
# 2. 内存使用率计算 (procfs /proc/meminfo)
# ------------------------------------------------------------------------------
ops_collect_mem() {
    local meminfo_file="${OPS_PROC_ROOT}/meminfo"
    if [[ ! -f "${meminfo_file}" ]]; then
        echo "0.0"
        return 0
    fi

    awk '
    BEGIN { total = 0; avail = 0; free = 0; buffers = 0; cached = 0; has_avail = 0; }
    /^MemTotal:/     { total = $2; }
    /^MemAvailable:/ { avail = $2; has_avail = 1; }
    /^MemFree:/      { free = $2; }
    /^Buffers:/      { buffers = $2; }
    /^Cached:/       { cached = $2; }
    END {
        if (total <= 0) {
            printf "0.0\n";
            exit;
        }
        if (has_avail == 0) {
            avail = free + buffers + cached;
        }
        used = total - avail;
        if (used < 0) used = 0;
        usage = (used / total) * 100.0;
        if (usage < 0.0) usage = 0.0;
        if (usage > 100.0) usage = 100.0;
        printf "%.1f\n", usage;
    }
    ' "${meminfo_file}"
}

# ------------------------------------------------------------------------------
# 3. 根分区磁盘使用率提取 (df -P /)
# ------------------------------------------------------------------------------
ops_collect_disk() {
    # 优先支持测试 Mock
    if [[ -n "${OPS_MOCK_DISK_PCT:-}" ]]; then
        printf "%.1f\n" "${OPS_MOCK_DISK_PCT}"
        return 0
    fi

    local disk_usage
    disk_usage=$(df -kP / 2>/dev/null | awk 'NR==2 { gsub("%", "", $5); print $5 }')
    if [[ -z "${disk_usage}" ]] || ! [[ "${disk_usage}" =~ ^[0-9]+$ ]]; then
        echo "0.0"
    else
        printf "%.1f\n" "${disk_usage}"
    fi
}

# ------------------------------------------------------------------------------
# 4. 网络吞吐量计算 (procfs /proc/net/dev)
# ------------------------------------------------------------------------------
_ops_read_net_bytes() {
    local net_file="${OPS_PROC_ROOT}/net/dev"
    if [[ ! -f "${net_file}" ]]; then
        echo "0 0"
        return 1
    fi

    awk '
    BEGIN { rx_total = 0; tx_total = 0; }
    NR > 2 {
        # 处理可能的冒号粘连情况，如 "eth0:12345" 或 "eth0: 12345"
        sub(/:/, " ", $1);
        if ($1 ~ /^lo$/ || $1 ~ /^lo[0-9]*$/) next; # 忽略本地回环
        
        # 网卡名后第一个数字为 rx_bytes，第 9 个数字为 tx_bytes
        rx = $2;
        tx = $10;
        if (rx ~ /^[0-9]+$/) rx_total += rx;
        if (tx ~ /^[0-9]+$/) tx_total += tx;
    }
    END {
        print rx_total, tx_total;
    }
    ' "${net_file}"
}

ops_collect_net() {
    local sample_interval="${1:-1}"
    local net1 net2
    net1=$(_ops_read_net_bytes)
    
    if [[ -z "${net1}" ]]; then
        echo "0.0 0.0"
        return 0
    fi

    if (( $(echo "${sample_interval} > 0" | awk '{print ($1 > 0)}') )); then
        sleep "${sample_interval}"
        net2=$(_ops_read_net_bytes)
    else
        echo "0.0 0.0"
        return 0
    fi

    awk -v n1="${net1}" -v n2="${net2}" -v dt="${sample_interval}" '
    BEGIN {
        split(n1, a1, " ");
        split(n2, a2, " ");
        rx_diff = a2[1] - a1[1];
        tx_diff = a2[2] - a1[2];

        # 处理计数器回绕或负数
        if (rx_diff < 0) rx_diff = 0;
        if (tx_diff < 0) tx_diff = 0;

        # 换算为 KB/s
        rx_kbps = (rx_diff / 1024.0) / dt;
        tx_kbps = (tx_diff / 1024.0) / dt;

        printf "%.1f %.1f\n", rx_kbps, tx_kbps;
    }
    '
}

# ------------------------------------------------------------------------------
# 5. 指标协同采集 (全指标并行/单次采样)
# ------------------------------------------------------------------------------
ops_collect_metrics() {
    local sample_interval="${1:-1}"
    local timestamp
    timestamp=$(date +%s)

    # 1. 记录 CPU 和 Net 的起始快照
    local cpu_stat1 net_stat1
    cpu_stat1=$(_ops_read_cpu_stat)
    net_stat1=$(_ops_read_net_bytes)

    # 2. 瞬时指标：内存与磁盘
    local mem_pct disk_pct
    mem_pct=$(ops_collect_mem)
    disk_pct=$(ops_collect_disk)

    # 3. 采样等待
    if (( $(echo "${sample_interval} > 0" | awk '{print ($1 > 0)}') )); then
        sleep "${sample_interval}"
    fi

    # 4. 记录 CPU 和 Net 的结束快照并计算
    local cpu_stat2 net_stat2
    cpu_stat2=$(_ops_read_cpu_stat)
    net_stat2=$(_ops_read_net_bytes)

    local cpu_pct
    cpu_pct=$(awk -v s1="${cpu_stat1}" -v s2="${cpu_stat2}" '
    BEGIN {
        split(s1, a1, " ");
        split(s2, a2, " ");
        total_diff = a2[1] - a1[1];
        idle_diff  = a2[2] - a1[2];
        if (total_diff <= 0) {
            printf "0.0\n";
        } else {
            usage = (1.0 - (idle_diff / total_diff)) * 100.0;
            if (usage < 0.0) usage = 0.0;
            if (usage > 100.0) usage = 100.0;
            printf "%.1f\n", usage;
        }
    }')

    local net_rates
    net_rates=$(awk -v n1="${net_stat1}" -v n2="${net_stat2}" -v dt="${sample_interval}" '
    BEGIN {
        split(n1, a1, " ");
        split(n2, a2, " ");
        if (dt <= 0) dt = 1.0;
        rx_diff = a2[1] - a1[1];
        tx_diff = a2[2] - a1[2];
        if (rx_diff < 0) rx_diff = 0;
        if (tx_diff < 0) tx_diff = 0;
        rx_kbps = (rx_diff / 1024.0) / dt;
        tx_kbps = (tx_diff / 1024.0) / dt;
        printf "%.1f\t%.1f\n", rx_kbps, tx_kbps;
    }')

    local net_rx net_tx
    net_rx=$(echo "${net_rates}" | awk '{print $1}')
    net_tx=$(echo "${net_rates}" | awk '{print $2}')

    # 输出标准 TSV 行: timestamp \t cpu \t mem \t disk \t net_rx \t net_tx
    printf "%s\t%s\t%s\t%s\t%s\t%s\n" \
        "${timestamp}" "${cpu_pct}" "${mem_pct}" "${disk_pct}" "${net_rx}" "${net_tx}"
}

# ------------------------------------------------------------------------------
# 命令行调度与多格式输出
# ------------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    mode="${1:---once}"
    sample_sec="${2:-1}"

    case "${mode}" in
        --once|--tsv)
            ops_collect_metrics "${sample_sec}"
            ;;
        --json)
            raw=$(ops_collect_metrics "${sample_sec}")
            IFS=$'\t' read -r ts cpu mem disk rx tx <<< "${raw}"
            printf '{"timestamp":%s,"cpu_usage_pct":%s,"mem_usage_pct":%s,"disk_usage_pct":%s,"net_rx_kbps":%s,"net_tx_kbps":%s}\n' \
                "${ts}" "${cpu}" "${mem}" "${disk}" "${rx}" "${tx}"
            ;;
        --kv)
            raw=$(ops_collect_metrics "${sample_sec}")
            IFS=$'\t' read -r ts cpu mem disk rx tx <<< "${raw}"
            echo "TIMESTAMP=${ts}"
            echo "CPU_USAGE_PCT=${cpu}"
            echo "MEM_USAGE_PCT=${mem}"
            echo "DISK_USAGE_PCT=${disk}"
            echo "NET_RX_KBPS=${rx}"
            echo "NET_TX_KBPS=${tx}"
            ;;
        *)
            echo "用法: $0 [--once | --tsv | --json | --kv] [sample_interval_sec]"
            exit 1
            ;;
    esac
fi
