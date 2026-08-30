# Ops-Monitor 常用操作与使用场景示例

本文档用通俗易懂的命令和场景，介绍在日常服务器运维中如何使用 Ops-Monitor。

---

## 场景 1：日常查看服务器状态

### 1.1 打开全屏实时动态仪表盘
平时 SSH 登录服务器后，想实时看看机器卡不卡、网络跑了多少：
```bash
ops
```
*(或者 `ops dashboard`)*
- **效果**：打开一个类似 `htop` 的全屏动态看板，实时刷新 CPU、内存、磁盘、上下行网速和火花线趋势。
- **操作**：按 `q` 退出，按 `r` 强制刷新，按 `h` 查看帮助。

---

### 1.2 快速打卡 / 单次体检（适合放到登录欢迎信息 MOTD）
只想快速看一眼当前机器健康状态，不需要常驻全屏：
```bash
ops status
```
- **效果**：输出一张带颜色的紧凑卡片，显示当前 CPU、内存、磁盘使用率、网速以及整体状态徽标（`NORMAL` / `WARNING` / `CRITICAL`）。

---

### 1.3 查看过去 24 小时的历史负载大图
排查昨晚半夜机器有没有被突发流量打满，或者内存有没有泄漏：
```bash
# 查看过去 24 小时 CPU 负载趋势图
ops history cpu

# 查看过去 24 小时 内存 使用趋势图
ops history mem

# 查看过去 24 小时 根分区磁盘 使用趋势图
ops history disk

# 查看过去 24 小时 网络吞吐 趋势图
ops history net
```
- **效果**：直接在 SSH 字符终端绘制完整的 24 小时 ASCII 曲线坐标图，并画出红色告警阈值参考线。

---

## 场景 2：告警配置（钉钉 / 企业微信 / 飞书 / Slack）

### 2.1 交互式向导配置（小白最推荐）
直接运行配置向导，根据命令行提示输入：
```bash
ops config
```
终端会逐项提示输入：
- CPU / 内存 / 磁盘告警阈值（比如 80%）
- 告警防抖与冷却时间（默认 30 分钟）
- Webhook 地址与加签 Secret（钉钉、企业微信、飞书、Slack 任意填）

---

### 2.2 命令行单项快速修改
如果只想临时改一个参数：
```bash
# 把 CPU 报警阈值改成 80%
ops config set ALERT_CPU_THRESHOLD 80

# 把内存报警阈值改成 90%
ops config set ALERT_MEM_THRESHOLD 90

# 设置钉钉机器人 Webhook 地址
ops config set WEBHOOK_DINGTALK_URL "https://oapi.dingtalk.com/robot/send?access_token=xxxx"

# 设置钉钉加签密钥
ops config set WEBHOOK_DINGTALK_SECRET "SECxxxx"
```

---

### 2.3 查看当前所有配置项
```bash
ops config list
```
*(默认会自动将 Token 和 Secret 脱敏掩码，避免截图或录屏泄密)*

---

### 2.4 测试告警通知是否能正常收到
配置好 Webhook 后，验证机器人能不能发通：
```bash
ops config test-alert
```
- **效果**：向群里发送一条模拟的告警卡片，确认网络连通与机器人权限无误。

---

## 场景 3：多台服务器之间一键迁移配置

如果有 10 台服务器需要统一配置，不需要每台机器重复手敲：

1. **在配置好的源服务器上导出单行密文**：
   ```bash
   ops config export --base64
   ```
   *(会输出一行类似 `Q09MTEVDVF9JTlRFUlZBTD0...` 的 Base64 编码文本)*

2. **在目标新服务器上一键导入生效**：
   ```bash
   ops config import --base64 "Q09MTEVDVF9JTlRFUlZBTD0..."
   ```

---

## 场景 4：后台服务与数据生命周期管理

### 4.1 检查后台自动采集服务状态
```bash
ops daemon status
# 或者
systemctl status ops-daemon
```

### 4.2 手动触发一次历史数据压缩归档
```bash
ops archive --run
```
*(将超过保留期限的旧指标打包压缩为 `.tar.gz` 移入归档目录，释放磁盘空间)*
