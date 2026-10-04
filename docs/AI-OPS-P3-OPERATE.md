# AI-Ops P3 — 运营化闭环计划（P0→P4）

目标：把 2026-10-04 打通的金丝雀遥测（`agent_disks` 正常、WSL2 虚拟盘如实
报错）推进到「采集失败可见、设备信息可辨识、物理盘可告警、通知可核验、
带外可取证」的运营闭环。

前置事实（2026-10-04 实测）：

- `lanhc-canary-agent`（`DESKTOP-QUNGQK7-agent`，node_id 11）是 WSL2，
  已装 `smartctl` shim，`agent_disks` 枚举 `/dev/sda`..`/dev/sdf`，
  `agent_smart` 对每块虚拟盘返回 `exit status 2`（无真实 ATA 属性，属正确行为）。
- `ops-runner` 已升 `lanhc-ops-runner:20261004-17`，把「可枚举但不可读」的盘
  逐盘计入 failures，不再静默跳过。
- 物理盘数据源：`baizor-agent`（MegaRAID，node 14）、`sg4028-agent`（SATA
  SSD，node 15）已有 `smart.*` 样本。
- hub 的 alert-rule 调度器已开（`AIOPS_SCHEDULER=1`，每 120s evaluate）。

## P0 采集失败可见（hub + worker + console）✅ 已完成

问题：worker 只在日志里报 `exit status 2`，控制台看不到「这台设备采集不了」。

- [x] `hs-console`：新增 `ai_ops_telemetry_failure` 表 + 模型 + 内部模块，
      保存最近一轮每台设备的采集失败（node / tool / device / error / collected_at）。
- [x] `hs-console`：新增 `POST /api/ai-ops/telemetry/failures`（ingest）与
      `GET /api/ai-ops/telemetry/failures`（按 tenant/node 查询，带 `latest=1`）。
- [x] `ops-runner`：`pushTelemetry()` 每轮把 `result.failures` 一并上报；
      node 级 failure（无 node_id）按 `node_name` 归并。
- [x] `hs-console`：`/ai-ops/telemetry` 增加「采集异常」区块，金丝雀显示为
      「虚拟盘 / 无真实 SMART」，而不是凭空消失。

验收：控制台 `/ai-ops/telemetry` 能看到 `lanhc-canary-agent` 的 6 条
`agent_smart (exit status 2)` + 1 条 `no SMART samples collected for host`。

## P1 设备信息增强 ✅ 已完成

- [x] 设备卡片补齐 `Platform / OS / Arch / Container|host / Client / Host IP`。
- [x] 金丝雀标注 `WSL2 / 虚拟盘 / 无物理 SMART`。
- [x] 物理机磁盘行显示型号、S/N、通电时长、温度、重映射/待映射/无法校正扇区。

验收：同一页能区分「容器 agent」和「WSL2 agent」，物理盘字段完整。

## P2 物理盘告警规则 ✅ 已完成

- [x] 为 tenant 1 建规则：
      `smart.reallocated_sectors >= 1` → P1；
      `smart.current_pending_sector >= 1` → P1；
      `smart.offline_uncorrectable >= 1` → P1；
      `smart.temperature_c >= 55` → P2；
      `smart.udma_crc_error_count >= 1` → P3。
- [x] 规则对 `baizor-agent` / `sg4028-agent` 生效，金丝雀不误报（无样本）。
- [x] 校验 evaluate 命中即开 incident，且带 `rule_id` 证据。

验收：`GET /api/ai-ops/telemetry/rules` 有 5 条启用规则；手工造样本能开 incident。

## P3 通知闭环 ✅ 已完成

- [x] 用企业微信 webhook 建 `incident_created` 通知规则（tenant 1）。
- [x] `POST /api/ai-ops/notifications/test` 发测试消息。
- [x] `/ai-ops/notification-logs` 能看到 `sent/failed`、HTTP 状态、payload。
- [x] 做一次「incident → 通知 → 日志」完整演练。

验收：企业微信实收一条 `[P1] ...` 消息，日志页有同日记录。

## P4 带外取证（Redfish/BMC）✅ 已验证（当前无可达 BMC，如实记录）

- [x] 确认 `sg4028-agent` / `baizor-agent` 是否有 BMC 可达。
- [x] 有则填 `REDFISH_URL/USER/PASSWORD`，只读验证 `bmc_get_sel`、`bmc_get_storage`（当前无 BMC，未填，待凭据）。
- [x] 无则如实记录「暂无带外」，不伪造。

验收：`bmc_triage` 对可达 BMC 返回结构化证据；不可达返回结构化错误。

## GPU / 其它 IP 采集（P0-P4 完成后追加）

- `lanhc-agent`：新增 `GET /v1/gpu`，用 `nvidia-smi --query-gpu` 采集型号/
  UUID/显存/利用率/温度/功耗；新增 `local_ips`，排除 tailnet（100.64/10 与
  fd7a ULA）后返回其它 LAN 地址；`-selfcheck` 也会打印 GPU 摘要。
- `mcp-lanhc`：新增 `agent_gpu` 工具，`agent_triage` 一并返回 GPU。
- `ops-runner`：遥测新增 `gpu.util_pct / gpu.memory_used_pct /
  gpu.temperature_c / gpu.power_w`，并把 `agent_inventory`+`agent_gpu` 写为
  `POST /api/ai-ops/device-info` 的持久快照。
- `hs-console`：新增 `ai_ops_device_info` 表、`/api/ai-ops/device-info`、
  设备卡显示 LAN IP/CPU/内存/GPU 徽标，遥测页支持 GPU 指标。
- 生产：`lanhc-agent-host:20261004-19`、`lanhc-ops-runner:20261004-20`、
  `hs-console:20261004-20`。金丝雀上报 RTX 3080；`sg4028-agent` 容器升级到
  `20261004-19` 并加 `runtime: nvidia` 后上报 2× Tesla V100-PCIE-32GB
  （各 32GB、41/39℃、~28W）；`baizor-agent` 为 CPU 机，GPU 0。
  三台 local IP 分别为 `172.31.145.44` / `172.21.0.2` / `172.20.0.2`。
- 发布：lanhc 发行包已升 `1.102.5+lanhc13`（含新 agent 二进制）。

## 变更记录

- 2026-10-04：计划落盘 `src/AI-OPS-P3-OPERATE.md`，从 P0 开始实施。
- P0：`hs-console:20261004-17` + `ops-runner:20261004-18` 上线；新增
  `ai_ops_telemetry_failure` 表、`/api/ai-ops/telemetry/failures`，控制台遥测页
  显示采集异常；生产已看到金丝雀 6 条 `exit status 2` + 1 条 host 级失败。
- P1：`hs-console:20261004-18` 上线；设备卡显示 WSL2 徽标、无 SMART 样本
  说明、采集异常原因与物理盘型号/S/N/CRC。
- P2：规则已校正：reallocated/current_pending/offline_uncorrectable 均 P1，
  CRC 阈值 0 → P3，温度 >55 → P3；全节点通配，金丝雀无样本不误报。
- P3：企业微信 `errcode:0` 实收，通知记录页显示 200/sent。
- P4：`192.168.100.202/.203` 是 Web Switch（管理口），不提供 Redfish；真实
  BMC 未接入，工具无凭据时返回结构化错误，不伪造带外证据。
