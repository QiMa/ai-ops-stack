# AI-Ops P2C — 稳定化与闭环计划

目标：把当前「能启动、但诊断不可靠」推进到「真实 headscale 数据 + 干净 JSON 诊断 + 卡死 run 可回收」。

## 一、当前问题（2026-10-03 实测）

1. **容器凭据不完整**
   `ai-ops-stack/.env` 只配了 `AIOPS_HUB_TOKEN`，缺 `HEADSCALE_URL/API_KEY`、`OPENAI_API_KEY`。
   结果：`run 5` 的证据采集 5 个调用全部失败（列表只记录了 4 个，`list_nodes` 失败被静默），
   Codex 无 key 挂满 `AIOPS_CODEX_TIMEOUT_MS`（600s）。
2. **诊断输出污染**
   `run 3/4` 的 `summary` 是 shell 文本（`bash\ncd /home/dev/src/ops-runner\n...`）。
   `worker/lib.js` 已改为优先解析 `codex exec --json` JSONL 的最后一条 `agent_message`，待真实复测。
3. **卡死 run**
   `run 2`、`run 5` 永久 `running`。worker 只消费 `queued`，没有 stale 回收。
4. **MCP 命名空间不兼容（上游限制）**
   非官方 provider（`huayu-v2`）按裸工具名调用，Responses API 下变成
   `unsupported call: <ns><name>`。已给全部工具加 `readOnlyHint`，但真正的兜底是
   worker 自己驱动工具（`worker/collect.js`），不依赖模型发起工具调用。

## 二、计划

### P2C-1 凭据注入与快速失败
- `ai-ops-stack/.env` 补 `HEADSCALE_URL/HEADSCALE_API_KEY`（本地联调用容器网关
  `http://172.19.0.1:8080`）与 `OPENAI_API_KEY`。
- worker 在 spawn Codex 前检查 `OPENAI_API_KEY`（或 `CODEX_HOME/auth.json`）缺失即
  立即 `fail fast`，不再挂满 600s。
- 修正 `ensureCodexHome()`：凭据为空时给出明确 warning，而不是静默跳过写 `auth.json`。

### P2C-2 确定性取证 + 干净诊断（核心）
- `worker/collect.js` 已落地：worker 直接驱动 mcp-lanhc 的只读 handler，
  把结构化证据塞进 prompt，模型只负责推理与产出 JSON。
- 修复 `list_nodes` 失败被静默的问题（采集失败要全部进 `failures`）。
- 用真实 headscale 复测：`list_nodes` 应成功；`agent_triage/bmc_triage` 无设备时
  如实记录为失败，不编造。
- 验收：`run 6` → incident 2 出现 `summary/risk/confidence/evidence/recommendations`
  全部合法、无 shell 文本的诊断。

### P2C-3 生命周期与回收
- worker 启动/每轮把「自己 worker_id、超过 N 分钟仍 running」的 run 标记 `failed`
  （经 hub 的 `complete(ok:false)`），回收 `run 2/5`。
- 或在 hub 侧加 stale reaper 路由，二者取一即可。

### P2C-4 回归
- ops-runner：`worker/lib.test.js`、`worker/collect.test.js`、`worker.js --self-test`。
- mcp-lanhc：`smoke / mock-integration / agent-mock / redfish-mock` + live-check。
- lanhc-hub：4 个容器内测试（smoke / telemetry / stream / scheduler）。
- 前端：`yarn build`。

### P2C-5 仓库与文档
- 推送 `mcp-lanhc`（`headscale.js`、`server.js` 未提交）与 `ops-runner`
  （`lib.js`、`collect.js`、`worker.js` 未提交）。
- `ai-ops-stack` 建 remote 推送；`lanhc-hub` 本地提交待推。
- 更新 `AI-OPS-DEPLOY-RUNBOOK.md`：凭据清单、reaper、命名空间/readOnlyHint 说明。

## 三、验证命令

```bash
# ops-runner 单元
cd /home/dev/src/ops-runner && node worker/lib.test.js && node worker/collect.test.js && node worker/worker.js --self-test

# mcp-lanhc
cd /home/dev/src/mcp-lanhc && node test/smoke.mjs && node test/mock-integration.mjs && node test/agent-mock.mjs && node test/redfish-mock.mjs

# 端到端（stack 起来后）
cd /home/dev/src/ai-ops-stack && docker compose up -d --build
T=$(cat /tmp/aiops_token)
curl -s -X POST -H "Authorization: Bearer $T" -H 'Content-Type: application/json' \
  -d '{"run_kind":"manual","model":"huayu-v2"}' \
  http://localhost:3081/api/ai-ops/incidents/2/investigate
curl -s -H "Authorization: Bearer $T" http://localhost:3081/api/ai-ops/incidents/2 | python3 -m json.tool
```

## 四、执行结果（2026-10-03）

| 项 | 状态 | 证据 |
| --- | --- | --- |
| P2C-1 凭据注入 + 快速失败 | ✅ | 容器 env 含 `HEADSCALE_*`/`OPENAI_API_KEY`；缺 key 时 worker 立即报错 |
| P2C-2 确定性取证 + 干净诊断 | ✅ | `run 8` 13.6s 完成，incident 2 得到 high/medium 结构化诊断 |
| P2C-3 卡死 run 回收 | ✅ | `run 2/5/6` 被标 `failed`；新增 `AIOPS_STALE_RUN_MS`/`AIOPS_REAP_ANY` |
| P2C-4 回归 | ✅ | ops-runner 3 套、mcp-lanhc 4 套、hub 4 套、前端 build 全绿 |
| P2C-5 仓库/文档 | 部分 | runbook + 本文档已更新；代码未提交/推送 |

### 关键根因（本次定位）

1. **容器缺 CA 证书**：`node:*-slim` 无 `/etc/ssl/certs`，Codex（rustls）所有
   HTTPS 请求只报 `error sending request`。已在 `ops-runner/Dockerfile` 安装
   `ca-certificates`。这是"模型一直转圈"的真正原因。
2. **MCP 命名空间不兼容**：非官方 provider 按裸工具名调用 → `unsupported call`。
   已改为 worker 内驱动只读工具（`worker/collect.js`），并在所有工具上声明
   `readOnlyHint`。
3. **`ensureCodexHome()` 重写 bug**：旧代码用当前 env 构造 `oldBlock`，
   导致持久化 volume 里的旧配置永不刷新。已改为按 section 重写。
4. **诊断解析**：只采纳 `codex exec --json` 中最后一条 `agent_message` 的 JSON。

## 四、风险与待办

- 生产凭据仍缺（真实 `HEADSCALE_*`、iDRAC/Redfish、`OPENAI_API_KEY`），
  端到端只能先用本地 headscale 容器 + 真实 LLM key。
- `huayu-v2` 对 Responses 工具命名空间的兼容是上游限制；当前方案是
  「worker 取证 + 模型推理」，Codex 内 MCP 工具调用降级为可选能力。
- 只读边界：所有工具无写操作；写动作仍需 hub 人工审批（P2 approval loop）。
