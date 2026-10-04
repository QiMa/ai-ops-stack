# AI-Ops P0 骨架交付说明（2026-10-03）

对应方案：`/home/dev/src/AI-OPS-CODEX-LANHC-PLAN.md`（P0 阶段）。

## 本次落地内容

| 产物 | 路径 | 说明 |
| --- | --- | --- |
| MCP server | `/home/dev/src/mcp-lanhc/` | 只读 MCP 工具，零依赖，stdio 传输 |
| 工具实现 | `mcp-lanhc/src/tools.js` | 6 个只读工具 |
| headscale 客户端 | `mcp-lanhc/src/headscale.js` | 复用 hub 的 `/api/v1` 读接口形状 |
| 协议层 | `mcp-lanhc/src/server.js` | JSON-RPC 2.0 / MCP 2024-11-05 握手 + `tools/list` + `tools/call` |
| 自测 | `mcp-lanhc/test/smoke.mjs`、`test/mock-integration.mjs` | 无 headscale 也能验证协议与取数逻辑 |
| 运行节点 | `/home/dev/src/ops-runner/` | Codex + mcp-lanhc，独立于 lanhc-hub |
| 部署模板 | `ops-runner/compose.yml`、`ops-runner/deploy/systemd.md` | 容器 / systemd 两种方式 |
| Codex 配置 | `ops-runner/codex.config.toml` | 注册 `mcp-lanhc`，沿用 `huayu-v2` provider |
| 提示词 | `ops-runner/prompts/triage-node.txt` | 节点离线自动诊断模板 |

## 本地验证结果

```text
$ node mcp-lanhc/test/smoke.mjs
smoke ok: tools listed = list_nodes, get_node, find_offline_nodes, list_users, get_policy, diagnose_node

$ node mcp-lanhc/test/mock-integration.mjs
mock integration ok: offline= 1 diagnose node= r930-01
```

## 运行环境说明

- 本 WSL 未启用 Docker Desktop 集成，`docker` 不可用，因此容器路径只提供模板，
  未实际 `up`。已用 Node 直跑 + mock API 完成端到端验证。
- 本地 headscale（`127.0.0.1:8080`）当前**未运行**，真实端到端测试留待控制面启动后执行：
  ```bash
  HEADSCALE_URL=http://127.0.0.1:8080 HEADSCALE_API_KEY=<key> \
    node /home/dev/src/mcp-lanhc/test/live-check.mjs
  ```

## 下一步（P1，待确认后动手）

1. `lanhc/cmd/lanhc-agent`：设备侧伴随进程（tsnet + 白名单接口 + SMART/journalctl）。
2. iDRAC/Redfish 适配器：SEL、物理盘健康，覆盖整机 down。
3. 时序基线：`telemetry_snapshot` + `alert_rule`。

## 安全边界

- P0 无任何写操作，无 `exec`，不在设备上装 Codex。
- `ops-runner` 与 `lanhc-hub` 分开部署；生产严禁 bypass-approvals。
