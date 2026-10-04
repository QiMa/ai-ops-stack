# AI-Ops P2 交付说明：lanhc-hub `ai-ops` 模块

对应方案：`/home/dev/src/AI-OPS-CODEX-LANHC-PLAN.md` P2 阶段。

## 交付内容（后端）

| 文件 | 说明 |
| --- | --- |
| `backend/migrations/20261003000001_ai_ops.js` | 7 张表：agent / telemetry / incident / diagnosis / action / run / alert_rule / notification_rule |
| `backend/models/ai-ops/*.js` | incident、agent、run、action、diagnosis、notification-rule |
| `backend/internal/ai-ops/incident.js` | incident CRUD + investigate + addDiagnosis |
| `backend/internal/ai-ops/action.js` | 动作审批状态机：pending → approved/rejected → executed/failed |
| `backend/internal/ai-ops/rules.js` | 通知规则 CRUD + `forEvent` |
| `backend/internal/ai-ops/notifier.js` | 无依赖 webhook 分发 + severity 门控 |
| `backend/internal/ai-ops/evaluator.js` | 离线/过期节点检测，生成 incident |
| `backend/routes/ai-ops/*` | REST：incidents / actions / notifications |
| `backend/routes/main.js` | 注册 `/api/ai-ops` |
| `backend/test/ai-ops-smoke.cjs` | 全链路冒烟测试 |

## API

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET/POST | `/api/ai-ops/incidents` | 列表 / 创建 |
| POST | `/api/ai-ops/incidents/scan` | 扫 headscale 离线/过期节点并开 incident |
| GET/PUT/DELETE | `/api/ai-ops/incidents/:id` | 详情 / 更新 / 删除 |
| POST | `/api/ai-ops/incidents/:id/investigate` | 入队 Codex 调查 |
| POST | `/api/ai-ops/incidents/:id/diagnoses` | 写入诊断结论 |
| GET/POST | `/api/ai-ops/actions` | 动作列表 / 创建 |
| POST | `/api/ai-ops/actions/:id/approve|reject|result` | 审批 / 回写结果 |
| GET/POST/PUT/DELETE | `/api/ai-ops/notifications/rules` | 通知规则 |
| POST | `/api/ai-ops/notifications/test` | 测试 webhook |

## 验证结果（容器内 SQLite 全量迁移 + 冒烟）

```text
migrations applied
tenant id= 1
incident id= 1 status= open
run id= 1 status= queued
diagnosis id= 1 confidence= medium
action id= 1 status= pending
action final= executed
rule id= 1 event= incident_created
double-approve correctly rejected
incidents waiting_approval= 1
AI-OPS SMOKE OK
```

## 安全边界

- 所有写操作（remediate）必须先 `approve`；未批准动作 `recordResult` 会被拒绝。
- `remediate` 必须带 `command_template`，否则 400。
- tenant 级 RBAC 复用 headscale `scope`；非 admin 只能访问自己租户。
- 通知 webhook 带 severity 门控；目标 URL 由规则表控制，不做任意 SSRF 外部调用（P3 再加 URL 白名单）。
- Codex 实际执行仍在 `ops-runner`（P0/P1），hub 只做编排、审批、审计。

## 下一步（P2-b / P3）

- `ops-runner` worker：消费 `ai_ops_run` 队列，调 `mcp-lanhc` 三源工具，回写 diagnosis/action。
- 定时 `scan` 调度器 + 前端页面（节点健康 / incident / 审批 / 通知规则）。
- 遥测入库 `ai_ops_telemetry` + 告警规则评估。

## 前端补充（P2-c）

- `frontend/js/app/api.js`：新增 `App.Api.AiOps`（incidents / scan / investigate / diagnoses / actions 审批 / 通知规则）。
- `frontend/js/app/ai-ops/incidents/main.js|ejs`：事件列表页（扫描离线、触发调查、查看动作）。
- `frontend/js/app/controller.js` + `router.js`：注册 `ai-ops/incidents` 路由。
- `frontend/js/app/ui/menu/main.ejs`：导航新增「AI 运维」入口。
- 构建验证：`yarn build` 成功（`js/main.bundle.js?v=1.0.15` 683 KiB，仅体积告警无错误）。


## 遥测与告警（P3-lite，2026-10-03）

- `backend/internal/ai-ops/telemetry.js`：样本入库、趋势查询、规则评估。
- `backend/routes/ai-ops/telemetry.js`：`POST /api/ai-ops/telemetry`、`GET /api/ai-ops/telemetry`、`POST /evaluate`、`GET|POST /rules`。
- 模型：`models/ai-ops/telemetry.js`、`models/ai-ops/alert-rule.js`。
- 规则：`operator` ∈ gt/lt/eq，`node_filter` 支持节点 id/名字或 `*`；同一节点同源异常复用 open incident（幂等）。
- 验证（容器内真实 HTTP + SQLite）：
  ```text
  ingested samples: 4
  alert rule 1
  evaluated -> incidents: 1 severity: p2
  re-evaluate idempotent: created=0
  trend points: 3 last= 148
  TELEMETRY SMOKE OK
  ```
  测试脚本：`backend/test/ai-ops-telemetry-smoke.cjs`

这正是 R930 二手盘场景的关键：`smart.reallocated_sectors` 从 0 → 148 的趋势触发告警，
而不是等单次快照越界。

## 定时调度器 + 前端审批/通知（2026-10-03）

- `backend/internal/ai-ops/scheduler.js`：无依赖 interval 调度器，任务顺序执行、错误隔离。
- `backend/internal/ai-ops/scheduler-boot.js`：`AIOPS_SCHEDULER=1` + `AIOPS_SCHEDULER_TOKEN` 启用；只在单实例启用避免重复。
- `backend/index.js`：启动时按需挂载调度器。
- 前端：
  - `ai-ops/incident/main.js|ejs`：事件详情、诊断展示、动作审批（批准/拒绝/记录结果）。
  - `ai-ops/notifications/main.js|ejs`：通知规则列表 + 新增 webhook。
  - 路由新增 `/ai-ops/incidents/:id`、`/ai-ops/notifications`；导航改为「AI 运维」下拉。
- 验证：调度器单测通过；`yarn build` 成功；后端两个冒烟测试全绿。

## 完整验证清单

```text
mcp-lanhc:
  smoke.mjs           16 tools
  mock-integration.mjs  headscale happy path
  agent-mock.mjs       in-band
  redfish-mock.mjs     out-of-band

lanhc-agent:
  go vet / go test / go build / -selfcheck

lanhc-hub backend (容器内 SQLite):
  ai-ops-smoke.cjs           incident/run/diagnosis/action/approval
  ai-ops-telemetry-smoke.cjs SMART 趋势 0→148 触发 P2、幂等
  scheduler-boot 测试        scan-offline-expired + evaluate-alert-rules

ops-runner:
  worker lib.test.js
  worker --self-test
  e2e dry-run               run=done incident=waiting_approval diagnoses=1
```
