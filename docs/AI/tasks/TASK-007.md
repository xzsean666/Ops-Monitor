# TASK-007: 终端字符图表与渲染引擎 (lib/render.sh)

## Objective
实现纯终端 ANSI/UTF-8 字符图形渲染引擎 `lib/render.sh`，无需 X11 或 Web UI，在 SSH 终端环境下提供单行 Sparkline 实时火花线和多行 24 小时高精度 ASCII/Braille 历史大图渲染。

## Scope
- **Sparkline 渲染器**：
  - 将一维时序数组归一化映射到 8 阶 UTF-8 字符（` ▂▃▄▅▆▇█`）
  - 支持 ANSI 颜色阶梯渐变（绿色 -> 黄色 -> 红色）
- **24 小时历史大图渲染器 (`ops history`)**：
  - 读取 TSV 历史数据（最多 1440 个采样点）
  - 自动获取终端列宽 $W$（如 80 列）并进行自适应降采样聚合（窗口 $K = \lfloor 1440 / W \rfloor$）
  - 绘制包含 Y 轴标尺（0% ~ 100% 或自适应流量量程）、虚线告警阈值线、曲线轨迹及 X 轴时间刻度的大图
- **紧凑状态卡片渲染器 (`ops status`)**：
  - 格式化输出带颜色徽标（NORMAL/WARN/CRIT）的服务器健康体检报告

## Allowed Files
- `lib/render.sh`
- `tests/test_render.sh`

## Dependencies
- TASK-001: 项目骨架与公共基础库
- TASK-004: TSV 存储与生命周期归档

## Inputs and Outputs
- **Inputs**: TSV 历史文件、实时指标数据数组、终端宽度与高度
- **Outputs**: 包含 ANSI 格式控制符与 UTF-8 字符的终端图表流

## Acceptance Criteria
1. Sparkline 算法正确处理最大值与最小值相同、全 0 或包含空值的情况。
2. 历史大图能够自适应 80/100/120 终端列宽，准确标定 Y 轴告警阈值虚线。
3. 在非交互终端（管道输出或 `NO_COLOR` 环境）下支持平滑降级或去除 ANSI 颜色码。

## Verification Commands
```bash
bash -n lib/render.sh
bash tests/test_render.sh
```

## Risks and Assumptions
- 终端需支持 UTF-8 字符集（现代 Linux 终端默认均支持）。

## Status
DONE
