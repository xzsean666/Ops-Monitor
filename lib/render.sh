#!/usr/bin/env bash
# ==============================================================================
# Ops-Monitor 终端字符图表与渲染引擎 (lib/render.sh)
# 纯终端 ANSI/UTF-8 字符图形渲染：Sparkline 火花线、进度条、24h 历史大图、体检卡片
# ==============================================================================

_RENDER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${_RENDER_LIB_DIR}/common.sh"
# shellcheck source=config_mgr.sh
source "${_RENDER_LIB_DIR}/config_mgr.sh"
# shellcheck source=storage.sh
source "${_RENDER_LIB_DIR}/storage.sh"
unset _RENDER_LIB_DIR

# Sparkline 阶梯字符字典 (8 阶)
SPARK_CHARS=(" " " " "▂" "▃" "▄" "▅" "▆" "▇" "█")

# ------------------------------------------------------------------------------
# 1. 进度条渲染器
# ------------------------------------------------------------------------------
ops_render_progress_bar() {
    local val="$1"        # 0.0 ~ 100.0
    local width="${2:-12}" # 进度条字符总宽
    local show_pct="${3:-1}"

    # 钳位在 0 ~ 100
    local int_val
    int_val=$(awk -v v="${val}" 'BEGIN {
        iv = int(v + 0.5);
        if (iv < 0) iv = 0;
        if (iv > 100) iv = 100;
        print iv;
    }')

    local filled=$(( int_val * width / 100 ))
    local empty=$(( width - filled ))

    local color="${COLOR_GREEN}"
    if [[ "${int_val}" -ge 85 ]]; then
        color="${COLOR_RED}"
    elif [[ "${int_val}" -ge 70 ]]; then
        color="${COLOR_YELLOW}"
    fi

    local bar=""
    local i
    for (( i=0; i<filled; i++ )); do bar+="█"; done
    for (( i=0; i<empty; i++ )); do bar+="░"; done

    if [[ "${show_pct}" == "1" ]]; then
        printf "%s[%s]%s %5.1f%%" "${color}" "${bar}" "${COLOR_RESET}" "${val}"
    else
        printf "%s[%s]%s" "${color}" "${bar}" "${COLOR_RESET}"
    fi
}

# ------------------------------------------------------------------------------
# 2. Sparkline 单行火花线渲染器
# ------------------------------------------------------------------------------
ops_render_sparkline() {
    local values_str="$1"       # 空格或制表符分隔的数值列表
    local min_val="${2:-}"      # 可选显式指定最小值
    local max_val="${3:-}"      # 可选显式指定最大值
    local use_color="${4:-1}"   # 是否启用颜色梯度

    local val_array=()
    read -r -a val_array <<< "${values_str}"

    local len=${#val_array[@]}
    if [[ "${len}" -eq 0 ]]; then
        echo ""
        return 0
    fi

    # 计算动态 min / max (若未指定)
    if [[ -z "${min_val}" || -z "${max_val}" ]]; then
        local min_calc max_calc
        read -r min_calc max_calc <<< "$(awk -v vals="${values_str}" '
        BEGIN {
            split(vals, a, /[ \t\n]+/);
            min = 999999999.0;
            max = -999999999.0;
            for (i in a) {
                if (a[i] ~ /^[0-9]+(\.[0-9]+)?$/) {
                    v = a[i] + 0.0;
                    if (v < min) min = v;
                    if (v > max) max = v;
                }
            }
            if (min > max) { min = 0.0; max = 100.0; }
            printf "%.2f %.2f\n", min, max;
        }')"
        min_val="${min_val:-$min_calc}"
        max_val="${max_val:-$max_calc}"
    fi

    awk -v vals="${values_str}" -v min="${min_val}" -v max="${max_val}" \
        -v use_col="${use_color}" -v cred="${COLOR_RED}" -v cyel="${COLOR_YELLOW}" \
        -v cgrn="${COLOR_GREEN}" -v crst="${COLOR_RESET}" '
    BEGIN {
        split("  ▂ ▃ ▄ ▅ ▆ ▇ █", chars, " ");
        split(vals, arr, /[ \t\n]+/);
        range = max - min;
        if (range <= 0) range = 1.0;

        out = "";
        for (i=1; i<=length(arr); i++) {
            if (arr[i] !~ /^[0-9]+(\.[0-9]+)?$/) continue;
            v = arr[i] + 0.0;
            norm = (v - min) / range;
            if (norm < 0.0) norm = 0.0;
            if (norm > 1.0) norm = 1.0;
            
            idx = int(norm * 8) + 1;
            if (idx > 8) idx = 8;
            if (idx < 1) idx = 1;

            glyph = chars[idx];
            if (use_col == 1) {
                if (v >= 85.0) col = cred;
                else if (v >= 70.0) col = cyel;
                else col = cgrn;
                out = out col glyph crst;
            } else {
                out = out glyph;
            }
        }
        print out;
    }'
}

# ------------------------------------------------------------------------------
# 3. 24 小时高精度 ASCII/Braille 历史大图渲染器
# ------------------------------------------------------------------------------
ops_render_history_chart() {
    local metric_type="${1:-cpu}"   # cpu, mem, disk, net
    local date_str="${2:-today}"
    local term_width="${3:-}"
    local term_height="${4:-12}"

    if [[ -z "${term_width}" ]]; then
        term_width=$(tput cols 2>/dev/null || echo 80)
    fi
    [[ "${term_width}" -lt 50 ]] && term_width=50
    [[ "${term_width}" -gt 160 ]] && term_width=160

    local col_idx=2 # TSV 默认第 2 列 (cpu)
    local title="CPU 历史负载趋势 (24h)"
    local unit="%"
    local is_percentage=1
    local alert_thresh
    alert_thresh=$(ops_config_get "ALERT_CPU_THRESHOLD" "85")

    case "${metric_type}" in
        cpu)
            col_idx=2
            title="CPU 负载使用率历史 (24h)"
            alert_thresh=$(ops_config_get "ALERT_CPU_THRESHOLD" "85")
            ;;
        mem)
            col_idx=3
            title="内存使用率历史 (24h)"
            alert_thresh=$(ops_config_get "ALERT_MEM_THRESHOLD" "90")
            ;;
        disk)
            col_idx=4
            title="根分区磁盘使用率历史 (24h)"
            alert_thresh=$(ops_config_get "ALERT_DISK_THRESHOLD" "85")
            ;;
        net|rx|tx)
            col_idx=5
            title="网络吞吐速率历史 (RX+TX KB/s)"
            unit="KB/s"
            is_percentage=0
            alert_thresh=""
            ;;
    esac

    # 读取当天所有 TSV 数据
    local tsv_records
    tsv_records=$(ops_storage_read_records "${date_str}" 1440)

    # 提取时间与目标数值
    local data_stream
    data_stream=$(echo "${tsv_records}" | awk -v col="${col_idx}" '
    BEGIN { FS="\t"; }
    NF >= col {
        # 若是 net 则取 $5 + $6
        if (col == 5 && NF >= 6) {
            val = $5 + $6;
        } else {
            val = $col;
        }
        print $1, val;
    }')

    # 调用 Awk 绘制完整高精度 ASCII 坐标系
    awk -v data="${data_stream}" -v width="${term_width}" -v height="${term_height}" \
        -v title="${title}" -v unit="${unit}" -v is_pct="${is_percentage}" \
        -v alert_val="${alert_thresh}" \
        -v cred="${COLOR_RED}" -v cyel="${COLOR_YELLOW}" -v cgrn="${COLOR_GREEN}" \
        -v cblu="${COLOR_CYAN}" -v cbld="${COLOR_BOLD}" -v crst="${COLOR_RESET}" -v cdim="${COLOR_DIM}" '
    BEGIN {
        # 1. 解析数据
        split(data, lines, "\n");
        n_points = 0;
        min_v = 999999.0;
        max_v = 0.0;

        for (i=1; i<=length(lines); i++) {
            if (length(lines[i]) == 0) continue;
            split(lines[i], p, " ");
            if (p[2] ~ /^[0-9]+(\.[0-9]+)?$/) {
                n_points++;
                ts_arr[n_points] = p[1];
                val_arr[n_points] = p[2] + 0.0;
                if (val_arr[n_points] < min_v) min_v = val_arr[n_points];
                if (val_arr[n_points] > max_v) max_v = val_arr[n_points];
            }
        }

        # 2. 量程决策
        if (is_pct == 1) {
            y_min = 0.0;
            y_max = 100.0;
        } else {
            y_min = 0.0;
            y_max = max_v * 1.25;
            if (y_max < 100.0) y_max = 100.0;
        }

        # 3. 确定绘图区尺寸
        y_label_width = 8;
        plot_w = width - y_label_width - 3;
        plot_h = height;
        if (plot_w < 30) plot_w = 30;

        # 4. 降采样聚合至 plot_w 个桶 (Bucket Averaging)
        for (w=1; w<=plot_w; w++) {
            bucket_vals[w] = 0.0;
            bucket_cnt[w]  = 0;
        }

        if (n_points > 0) {
            for (i=1; i<=n_points; i++) {
                b_idx = int(((i - 1) / n_points) * plot_w) + 1;
                if (b_idx > plot_w) b_idx = plot_w;
                bucket_vals[b_idx] += val_arr[i];
                bucket_cnt[b_idx]++;
            }
            for (w=1; w<=plot_w; w++) {
                if (bucket_cnt[w] > 0) {
                    chart_y[w] = bucket_vals[w] / bucket_cnt[w];
                } else {
                    chart_y[w] = (w > 1) ? chart_y[w-1] : 0.0;
                }
            }
        } else {
            for (w=1; w<=plot_w; w++) chart_y[w] = 0.0;
        }

        # 5. 初始化网格缓冲
        for (r=1; r<=plot_h; r++) {
            for (c=1; c<=plot_w; c++) {
                grid[r, c] = " ";
            }
        }

        # 6. 计算告警参考线行号
        alert_row = -1;
        if (alert_val != "" && alert_val + 0 > 0) {
            norm_a = (alert_val - y_min) / (y_max - y_min);
            alert_row = plot_h - int(norm_a * (plot_h - 1));
        }

        # 7. 填入告警线
        if (alert_row >= 1 && alert_row <= plot_h) {
            for (c=1; c<=plot_w; c++) {
                grid[alert_row, c] = cdim "-" crst;
            }
        }

        # 8. 绘制数据点与曲线
        for (c=1; c<=plot_w; c++) {
            v = chart_y[c];
            norm = (v - y_min) / (y_max - y_min);
            if (norm < 0.0) norm = 0.0;
            if (norm > 1.0) norm = 1.0;
            
            row = plot_h - int(norm * (plot_h - 1));
            if (row < 1) row = 1;
            if (row > plot_h) row = plot_h;

            # 着色与字符
            col = cgrn;
            if (v >= 85.0) col = cred;
            else if (v >= 70.0) col = cyel;

            grid[row, c] = col "●" crst;
        }

        # 9. 渲染输出图表头部
        printf "\n%s=== [Ops-Monitor] %s ===%s (采样点: %d)\n", cbld, title, crst, n_points;
        if (alert_val != "") {
            printf "%s告警阈值线: %s%%%s\n", cdim, alert_val, crst;
        }
        printf "\n";

        # 10. 渲染 Y 轴与网格主体
        for (r=1; r<=plot_h; r++) {
            # 计算该行对应的数值
            row_norm = (plot_h - r) / (plot_h - 1.0);
            row_val = y_min + row_norm * (y_max - y_min);

            # Y 轴标尺 (每隔两行或首尾打印数字)
            if (r == 1 || r == plot_h || r % 3 == 1) {
                if (is_pct == 1) {
                    printf "%5.0f%% |", row_val;
                } else {
                    printf "%5.0f |", row_val;
                }
            } else {
                printf "       |";
            }

            # 输出图表列
            for (c=1; c<=plot_w; c++) {
                printf "%s", grid[r, c];
            }
            printf "\n";
        }

        # 11. 渲染 X 轴横线
        printf "       +";
        for (c=1; c<=plot_w; c++) printf "-";
        printf ">\n";

        # 12. 渲染 X 轴时间刻度 (00:00, 04:00, 08:00, 12:00, 16:00, 20:00, 24:00)
        printf "        00:00";
        spaces_step = int((plot_w - 35) / 5);
        if (spaces_step < 1) spaces_step = 1;
        times[1] = "04:00"; times[2] = "08:00"; times[3] = "12:00"; times[4] = "16:00"; times[5] = "20:00"; times[6] = "24:00";
        
        curr_pos = 13;
        for (t=1; t<=6; t++) {
            target_pos = int(t * (plot_w / 6.0)) + 8;
            while (curr_pos < target_pos) {
                printf " ";
                curr_pos++;
            }
            printf "%s", times[t];
            curr_pos += length(times[t]);
        }
        printf " (时间)\n\n";
    }'
}

# ------------------------------------------------------------------------------
# 4. 紧凑健康体检报告卡片 (ops status)
# ------------------------------------------------------------------------------
ops_render_status_card() {
    local raw_metrics="${1:-}"
    
    if [[ -z "${raw_metrics}" ]]; then
        raw_metrics=$(ops_collect_metrics 0.5)
    fi

    local ts cpu mem disk rx tx
    IFS=$'\t' read -r ts cpu mem disk rx tx <<< "${raw_metrics}"

    local host
    host=$(_ops_get_hostname)
    local uptime_str
    uptime_str=$(uptime -p 2>/dev/null || uptime | awk -F',' '{print $1}')

    # 查询告警状态
    local overall_state="NORMAL"
    if declare -f ops_alert_get_overall_status >/dev/null 2>&1; then
        overall_state=$(ops_alert_get_overall_status)
    fi

    local badge="${COLOR_BG_GREEN}${COLOR_WHITE} NORMAL ${COLOR_RESET}"
    if [[ "${overall_state}" == "CRITICAL" ]]; then
        badge="${COLOR_BG_RED}${COLOR_WHITE} CRITICAL ${COLOR_RESET}"
    elif [[ "${overall_state}" == "WARN" ]]; then
        badge="${COLOR_BG_YELLOW}${COLOR_WHITE} WARNING ${COLOR_RESET}"
    fi

    # 提取最近 15 个 CPU 采样点渲染火花线
    local recent_tsv
    recent_tsv=$(ops_storage_read_records "today" 20)
    local recent_cpus=""
    if [[ -n "${recent_tsv}" ]]; then
        recent_cpus=$(echo "${recent_tsv}" | awk -F'\t' '{print $2}' | tr '\n' ' ')
    fi
    if [[ -z "${recent_cpus}" ]]; then
        recent_cpus="${cpu}"
    fi
    local spark
    spark=$(ops_render_sparkline "${recent_cpus}" 0 100 1)

    cat <<EOF

${COLOR_BOLD}┌────────────────────────────────────────────────────────────────────────┐${COLOR_RESET}
${COLOR_BOLD}│  Ops-Monitor 服务器健康体检报告                     [${badge}${COLOR_BOLD}] │${COLOR_RESET}
${COLOR_BOLD}├────────────────────────────────────────────────────────────────────────┤${COLOR_RESET}
│  主机节点: ${COLOR_CYAN}${host}${COLOR_RESET}
│  运行时间: ${uptime_str}
│  检查时间: $(date '+%Y-%m-%d %H:%M:%S')
│
│  CPU  使用率: $(ops_render_progress_bar "${cpu}" 15 1)
│  内存 使用率: $(ops_render_progress_bar "${mem}" 15 1)
│  磁盘 使用率: $(ops_render_progress_bar "${disk}" 15 1)
│  网络 吞吐量: RX ${COLOR_GREEN}${rx} KB/s${COLOR_RESET}  |  TX ${COLOR_CYAN}${tx} KB/s${COLOR_RESET}
│
│  CPU 近期趋势: ${spark}
${COLOR_BOLD}└────────────────────────────────────────────────────────────────────────┘${COLOR_RESET}

EOF
}
