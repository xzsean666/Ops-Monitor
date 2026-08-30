#!/usr/bin/env bash
# ==============================================================================
# Ops-Monitor TSV 存储与数据生命周期归档引擎 (lib/storage.sh)
# 负责指标 TSV 滚动落盘、并发锁保护、跨天检测与 Tar.Gz 压缩归档
# ==============================================================================

_STORAGE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${_STORAGE_LIB_DIR}/common.sh"
# shellcheck source=config_mgr.sh
source "${_STORAGE_LIB_DIR}/config_mgr.sh"
# shellcheck source=collector.sh
source "${_STORAGE_LIB_DIR}/collector.sh"
unset _STORAGE_LIB_DIR

# 标准 TSV 表头定义
OPS_TSV_HEADER="#timestamp	cpu_usage_pct	mem_usage_pct	disk_usage_pct	net_rx_kbps	net_tx_kbps"

# ------------------------------------------------------------------------------
# 定位当前指标文件路径
# ------------------------------------------------------------------------------
ops_storage_get_current_file() {
    local date_str="${1:-$(date +%Y%m%d)}"
    echo "${OPS_CURRENT_DATA_DIR}/metrics_${date_str}.tsv"
}

# ------------------------------------------------------------------------------
# 写入单行指标 (并发安全)
# ------------------------------------------------------------------------------
ops_storage_append() {
    local line="$1"
    local date_str="${2:-$(date +%Y%m%d)}"
    
    if [[ -z "${line}" ]]; then
        return 0
    fi

    ops_ensure_dirs || return "${OPS_EXIT_PERM_ERR}"

    local target_file
    target_file=$(ops_storage_get_current_file "${date_str}")

    # 获取排他锁保护写入
    if ! ops_lock_acquire 3; then
        ops_log_warn "写入指标获取锁超时，放弃本次落盘: ${target_file}"
        return "${OPS_EXIT_LOCK_ERR}"
    fi

    # 若文件不存在或为空，写入标准表头
    if [[ ! -f "${target_file}" ]] || [[ ! -s "${target_file}" ]]; then
        echo -e "${OPS_TSV_HEADER}" > "${target_file}"
    fi

    # 追加指标行
    echo -e "${line}" >> "${target_file}"

    ops_lock_release
    return 0
}

# ------------------------------------------------------------------------------
# 单步协同执行：采集并落盘
# ------------------------------------------------------------------------------
ops_storage_collect_and_store() {
    local sample_sec="${1:-1}"
    local metrics_line
    metrics_line=$(ops_collect_metrics "${sample_sec}")
    
    if [[ -n "${metrics_line}" ]]; then
        ops_storage_append "${metrics_line}"
        echo "${metrics_line}"
    fi
}

# ------------------------------------------------------------------------------
# 读取最近指标数据 (过滤表头注释)
# ------------------------------------------------------------------------------
ops_storage_read_records() {
    local date_str="${1:-today}"
    local max_lines="${2:-1440}"
    local target_file=""

    if [[ "${date_str}" == "today" ]]; then
        target_file=$(ops_storage_get_current_file)
    else
        target_file=$(ops_storage_get_current_file "${date_str}")
    fi

    if [[ ! -f "${target_file}" ]]; then
        return 0
    fi

    # 提取非注释行，最多返回 max_lines 行
    grep -v '^#' "${target_file}" 2>/dev/null | tail -n "${max_lines}" || true
}

# ------------------------------------------------------------------------------
# 数据生命周期归档与清理流水线
# ------------------------------------------------------------------------------
ops_storage_archive() {
    local force="${1:-0}"
    local today
    today=$(date +%Y%m%d)

    local archive_dir
    archive_dir=$(ops_config_get "ARCHIVE_DIR" "")
    local retention_days
    retention_days=$(ops_config_get "RETENTION_DAYS" "1")

    if [[ ! -d "${OPS_CURRENT_DATA_DIR}" ]]; then
        return 0
    fi

    # 遍历当前目录下的所有 metrics_*.tsv 文件
    local file
    for file in "${OPS_CURRENT_DATA_DIR}"/metrics_*.tsv; do
        [[ ! -f "${file}" ]] && continue

        local fname
        fname="$(basename "${file}")"
        # 提取文件名中的日期: metrics_YYYYMMDD.tsv
        if [[ "${fname}" =~ ^metrics_([0-9]{8})\.tsv$ ]]; then
            local file_date="${BASH_REMATCH[1]}"
            
            # 若是当天文件且非强制归档，跳过
            if [[ "${file_date}" == "${today}" ]] && [[ "${force}" != "1" ]]; then
                continue
            fi

            # 判定归档或删除
            if [[ -n "${archive_dir}" ]]; then
                mkdir -p "${archive_dir}" 2>/dev/null || {
                    ops_log_err "无法创建归档目录: ${archive_dir}"
                    continue
                }

                local archive_tar="${archive_dir}/metrics_${file_date}.tar.gz"
                
                # 打包压缩
                if tar -czf "${archive_tar}" -C "${OPS_CURRENT_DATA_DIR}" "${fname}" 2>/dev/null; then
                    rm -f "${file}"
                    ops_log_info "历史指标已成功归档: ${fname} -> ${archive_tar}"
                else
                    ops_log_err "归档打包失败: ${file}"
                fi
            else
                # 无归档目录，直接清理以释放磁盘空间
                rm -f "${file}"
                ops_log_info "已清理过期指标文件: ${fname}"
            fi
        fi
    done
    return 0
}
