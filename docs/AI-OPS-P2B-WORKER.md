# AI-Ops P2-b 交付说明：ops-runner worker + run 状态机

对应方案：`/home/dev/src/AI-OPS-CODEX-LANHC-PLAN.md` P2 阶段。

## 交付内容

| 文件 | 说明 |
| --- | --- |
| `lanhc-hub/backend/internal/ai-ops/run.js` | run 状态机：queued → running → done/failed；claim 用状态卡点保证单 worker |
| `lanhc-hub/backend/routes/ai-ops/runs.js` | `/api/ai-ops/runs`：list/get/claim/complete |
| `lanhc-hub/backend/routes/ai-ops/index.js` | 注册 `/runs` |
| `ops-runner/worker/worker.js` | worker：消费 queued → 调 Codex → 回写 diagnosis + complete |
| `ops-runner/worker/lib.js` | prompt 构造 + Codex 输出解析（脱 code fence / 平衡 JSON / 降级） |
| `ops-runner/worker/lib.test.js` | worker 纯逻辑单测 |

## worker 数据流

```
hub(run=queued) --claim--> worker --buildPrompt--> Codex(mcp-lanhc 只读工具)
      <--POST /diagnoses--            <--JSON 结论--
      <--POST /runs/:id/complete--
```

- worker 只产出诊断，**不执行 remediation**；动作继续走 P2 的 pending → approve → executed。
- `claim` 仅在 `queued` 时成功，避免多个 worker 重复处理。
- Codex 调用使用 `codex exec --json`，可用 `--dry-run` 在不装 Codex 时验证整条链路。

## 配置

```bash
AIOPS_HUB_URL=https://console.lanhc.com/api   # 经 nginx 需带 /api；直连后端则用根地址
AIOPS_HUB_TOKEN=<hub 只读/编排 token>
AIOPS_WORKER_ID=ops-runner-01
AIOPS_MODEL=huayu-v2
HEADSCALE_URL=...  HEADSCALE_API_KEY=...      # 注入 mcp-lanhc
REDFISH_URL=...    REDFISH_USER=... REDFISH_PASSWORD=...
```

## 验证结果（容器内真实 HTTP + 真实 JWT + 真实 DB，worker dry-run）

```text
incident 1
run 1 queued
[worker] e2e-worker polling http://127.0.0.1:45127 (once)
[worker] claiming run 1
[worker] run 1 done: [dry-run] R930 down
E2E WORKER OK: run=done incident=waiting_approval diagnoses=1
```

单测：

```text
node ops-runner/worker/lib.test.js
worker lib tests OK
```

## 安全

- worker 默认只读诊断，不生成 action、不执行命令。
- `claim` 卡点 + `running` 卡点防止并发与重复完成。
- Codex 出网与 mcp-lanhc 只读工具沿用 P0/P1 安全边界。
