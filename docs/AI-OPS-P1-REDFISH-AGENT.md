# AI-Ops P1-b 交付说明：Redfish 带外适配器 + agent 代理工具

对应方案：`/home/dev/src/AI-OPS-CODEX-LANHC-PLAN.md` P1 阶段。

## 本次交付

`mcp-lanhc` 工具面从纯 headscale 扩展为三类数据源：

| 数据源 | 工具前缀 | 说明 |
| --- | --- | --- |
| headscale | `list_nodes` / `get_node` / `diagnose_node` 等 | 控制面元数据（P0） |
| lanhc-agent | `agent_inventory` / `agent_health` / `agent_smart` / `agent_logs` / `agent_triage` | in-band 取证（P1-a） |
| iDRAC/Redfish | `bmc_list_systems` / `bmc_get_system` / `bmc_get_storage` / `bmc_get_sel` / `bmc_triage` | out-of-band 取证（P1-b） |

新增文件：

- `mcp-lanhc/src/agent-tools.js`：经 tailnet 代理到设备侧 `lanhc-agent`（零依赖 HTTP）。
- `mcp-lanhc/src/redfish.js`：只读 Redfish 客户端（Basic Auth，容忍自签证书）。
- `mcp-lanhc/src/redfish-tools.js`：5 个只读 BMC 工具，`bmc_triage` 一次聚合系统/物理盘/SEL。
- 测试：`mcp-lanhc/test/agent-mock.mjs`、`mcp-lanhc/test/redfish-mock.mjs`。

## 验证结果

```text
node test/smoke.mjs
  tools listed = ... bmc_list_systems bmc_get_system bmc_get_storage bmc_get_sel bmc_triage
                 agent_inventory agent_health agent_smart agent_logs agent_triage

node test/agent-mock.mjs
  agent mock ok: host= r930-01 failed= kdump.service

node test/redfish-mock.mjs
  redfish mock ok: model= PowerEdge R930 driveHealth= Critical sel= Critical
```

## 安全要点

- Redfish 只读：`power/reset` 等写操作未实现，等 P2 审批闭环。
- Redfish 凭据只存在 `ops-runner` 侧环境/密文，不会下发到设备。
- agent 工具不接受自由 shell；仅调用 `lanhc-agent` 白名单端点。

## 下一步（P2）

lanhc-hub `ai-ops` 模块：事件检测、incident、通知、审批、审计，把这三类只读
工具接到自动诊断 + 人审批闭环。
