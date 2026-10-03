# lanhc AI-Ops 部署 Runbook

> 目标：把 `lanhc` + `headscale` + `lanhc-hub` + `mcp-lanhc` + `ops-runner` 的
> AI-Ops 能力部署到真实环境。R930 二手盘这类“退化型”故障是首要验收场景。

## 0. 组件清单

| 组件 | 源码 | 远端 | 部署位置 |
| --- | --- | --- | --- |
| `lanhc-agent` | `lanhc/cmd/lanhc-agent` | 随 lanhc 构建 | 每台被管设备 |
| `mcp-lanhc` | `mcp-lanhc/` | `git@github.com:QiMa/mcp-lanhc.git` | ops-runner |
| `ops-runner` | `ops-runner/` | `git@github.com:QiMa/ops-runner.git` | 控制面（独立容器/VM） |
| `lanhc-hub ai-ops` | `lanhc-hub/backend` | lanhc-hub 主仓库 | hub 容器 |
| 一键栈 | `ai-ops-stack/` | `git@github.com:QiMa/ai-ops-stack.git`（待建仓） | 本地/小规模闭环（hub + ops-runner） |

## 0.5 最快路径：一键栈（本地/小规模闭环）

需要把 hub + ops-runner 一次拉起时，用 `ai-ops-stack/`：

```bash
cd /home/dev/src/ai-ops-stack
cp .env.example .env   # 填 AIOPS_HUB_TOKEN / HEADSCALE_* / OPENAI_API_KEY 等
docker compose up -d --build
```

- `hub` 暴露在 `http://localhost:3081`（nginx 81 -> 3081）。
- `ops-runner` 镜像内置 Codex CLI（`CODEX_VERSION`，默认 0.159.3）与 `mcp-lanhc`，
  不再依赖宿主机的 Codex 安装。
- 容器内地址 `AIOPS_HUB_URL=http://hub:3000`（不经 nginx，不要带 `/api`）；
  宿主机/生产走 nginx 时才用 `https://console.lanhc.com/api`。
- 该栈不包含 headscale 与 lanhc-agent；需要已有 tailnet。

健康检查：

```bash
curl -s http://localhost:3081/api/                      # {"status":"OK",...}
docker compose logs -f ops-runner
docker compose run --rm --no-deps ops-runner node /workspace/ops-runner/worker/worker.js --self-test
```

## 1. 前置条件

- headscale 已运行，且有只读 API key（`/apikey` 可访问）。
- 每台设备已安装 `lanhc`（或 lanhcd），并已加入 tailnet。
- `lanhc-hub` 已部署，headscale instance + tenant 已配好。
- 控制面有一个可访问 iDRAC 的网络路径（带外）。
- `ops-runner` 所在节点已安装 Codex CLI 与 Node 22。

## 2. 设备侧：`lanhc-agent`

> 生产上线（金丝雀、验收、回滚）见 `AI-OPS-AGENT-PROD-ROLLOUT.md`。

### 2.1 构建与打包

`lanhc-agent` 随 `build-tailscale-custom.sh` 一起构建，Linux tarball 已包含：

- `lanhc-agent` 二进制
- `agent/install-agent.sh` 安装脚本
- `agent/lanhc-agent.service` systemd 单元
- `agent/lanhc-agent.defaults` 环境文件

```bash
cd /home/dev/src
TARGETS="linux/amd64" VERSION=1.102.4+lanhc9 OUT=/home/dev/out/lanhc bash build-tailscale-custom.sh
```

### 2.2 首次注册（发行包一条命令）

先在 headscale 创建带 tag 的 preauthkey：

```bash
headscale preauthkeys create --user <username> --tags tag:lanhc-agent --expiration 24h
```

解包后直接安装并注册：

```bash
tar xzf lanhc_linux_amd64.tar.gz
cd lanhc_linux_amd64
sudo TS_AUTHKEY=tskey-auth-XXXX ./agent/install-agent.sh
```

脚本自动完成：装二进制到 `/usr/local/bin`、写 systemd unit 和
`/etc/default/lanhc-agent`、写入 `TS_AUTHKEY`、`daemon-reload` + `enable --now`。

之后 `/etc/default/lanhc-agent` 里的 `TS_AUTHKEY` 可清空，节点身份已存在
`/var/lib/lanhc-agent`，重启不会要求重新注册。

默认值（无参数即可运行）：

- 节点名：`<本机主机名>-agent`
- 控制面：编译进二进制的 `ipn.DefaultControlURL`
- 状态目录：`/var/lib/lanhc-agent`
- 监听地址：`tailnet :8088`
- tags：空，由 preauthkey 下发

### 2.3 systemd

随包分发到 `agent/lanhc-agent.service`，关键项：

```ini
[Service]
EnvironmentFile=-/etc/default/lanhc-agent
ExecStart=/usr/local/bin/lanhc-agent
StateDirectory=lanhc-agent
ProtectSystem=full
ProtectHome=true
NoNewPrivileges=true
PartOf=lanhcd.service
```

### 2.4 ACL

只允许控制面访问 agent：

```jsonc
{
  "acls": [
    {
      "action": "accept",
      "src": ["tag:ai-ops-runner"],
      "dst": ["tag:lanhc-agent:8088"]
    }
  ]
}
```

## 3. 控制面：`ops-runner`

### 3.1 拉取

```bash
git clone git@github.com:QiMa/ops-runner.git /opt/ops-runner
git clone git@github.com:QiMa/mcp-lanhc.git /opt/ops-runner/mcp-lanhc
```

### 3.2 配置

```bash
cd /opt/ops-runner
cp .env.example .env
```

`.env` 关键项：

```bash
HEADSCALE_URL=https://headscale.lanhc.com
HEADSCALE_API_KEY=<只读 API key>
REDFISH_URL=https://idrac.lanhc
REDFISH_USER=<只读账号>
REDFISH_PASSWORD=<密码>

AIOPS_HUB_URL=https://console.lanhc.com/api
AIOPS_HUB_TOKEN=<hub admin token>
AIOPS_MODEL=huayu-v2
CODEX_BASE_URL=https://baizor.com/v1
CODEX_WIRE_API=responses
OPENAI_API_KEY=<模型 key>
```

### 3.3 启动 worker

```bash
cd /opt/ops-runner
node worker/worker.js --self-test      # 纯逻辑自检
node worker/worker.js --once --dry-run # 连 hub 验证闭环（不调 LLM）
node worker/worker.js                  # 常驻轮询
```

生产可用 systemd 常驻，或放到单实例调度。

## 4. lanhc-hub：`ai-ops`

### 4.1 数据库迁移

部署新镜像时自动跑 `migrate.latest()`；若手动：

```bash
cd /home/dev/src/lanhc-hub/backend
node migrate.js
```

### 4.2 调度器（单实例启用）

```bash
AIOPS_SCHEDULER=1
AIOPS_SCHEDULER_TOKEN=<admin token>
AIOPS_SCHEDULER_TICK_MS=60000
AIOPS_SCAN_INTERVAL_MS=60000
AIOPS_RULE_INTERVAL_MS=120000
```

**多副本时只在一个 hub 实例开启**，否则会重复建 incident。

### 4.3 前端入口

- 事件：`/ai-ops/incidents`
- 事件详情：`/ai-ops/incidents/:id`（含实时调查进度）
- 通知规则：`/ai-ops/notifications`

## 5. 告警与通知配置

### 5.1 通知规则

```bash
curl -X POST https://console.lanhc.com/api/ai-ops/notifications/rules \
  -H "Authorization: Bearer <token>" -H "Content-Type: application/json" \
  -d '{"tenant_id":1,"event":"incident_created","channel":"webhook","target":"https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=...","severity_min":"p2"}'
```

支持的事件：`incident_created` / `incident_resolved` / `action_pending` /
`action_executed` / `ai_finished`。

### 5.2 SMART 告警规则（R930 二手盘）

```bash
curl -X POST https://console.lanhc.com/api/ai-ops/telemetry/rules \
  -H "Authorization: Bearer <token>" -H "Content-Type: application/json" \
  -d '{"tenant_id":1,"metric":"smart.reallocated_sectors","operator":"gt","threshold":50,"severity":"p2","node_filter":"*"}'
```

建议再加：`smart.current_pending_sector > 10`、
`smart.udma_crc_error_count > 100`、`smart.temperature_c > 60`。

### 5.3 样本上报

设备侧 agent 定时把 SMART 关键属性推给 hub（示例）：

```bash
curl -X POST https://console.lanhc.com/api/ai-ops/telemetry \
  -H "Authorization: Bearer <token>" -H "Content-Type: application/json" \
  -d '{"tenant_id":1,"node_id":"r930-01","samples":[
        {"metric":"smart.reallocated_sectors","value":148},
        {"metric":"smart.temperature_c","value":44}]}'
```

## 6. 验证验收（R930 场景）

1. 设备掉线 → hub 调度器扫出 `offline` incident，P2 通知到 webhook。
2. 控制台点「让 AI 调查」→ `ops-runner` claim → Codex 调 `mcp-lanhc`：
   - `list_nodes` / `diagnose_node`（headscale）
   - `agent_triage` / `agent_smart`（设备存活时）
   - `bmc_triage` / `bmc_get_storage` / `bmc_get_sel`（整机 down 时）
3. 诊断回写：根因、证据、建议动作、风险/置信度。
4. 人在控制台批准动作 → 记录执行结果 → incident 解决。
5. 复盘：把二手盘 SMART 阈值沉淀为 `telemetry/rules`，下次提前告警。


## 6.5 本机闭环验证（无需生产 tailnet）

已在 WSL 用 `headscale/headscale:latest` + `lanhc-agent` + `lanhcd` 验证真实链路：

1. 起 headscale（临时容器，`listen 8080`，SQLite + 外部 DERP map）。
2. 建 user、API key、带 `tag:lanhc-agent` 的 preauth key。
3. 设置 policy：`tagOwners` 中的 owner 必须写 `user@`（v0.29 policy v2 要求），
   `acls` 放行 `tag:ai-ops-runner -> tag:lanhc-agent:8088`。
4. 用发行包安装：解包 → `TS_AUTHKEY=<tagged key> NO_SYSTEMD=1 ./agent/install-agent.sh`
   → 启动 `/usr/local/bin/lanhc-agent`（容器内用 `-control-url http://host.docker.internal:8080`）。
5. `mcp-lanhc` live-check：`list_nodes/find_offline_nodes/get_node/diagnose_node`
   正确返回；`agent_inventory/agent_health/agent_triage` 经 tailnet 到 agent 成功。

### 6.5.1 2026-10-03 发行包端到端验证结果

用 `build-tailscale-custom.sh` 产出的 tarball 在干净容器里跑通完整闭环：

- 安装脚本正常落盘二进制/unit/defaults，`NO_SYSTEMD=1` 时不依赖 systemd。
- 节点成功注册为 `tag:lanhc-agent`，headscale 显示 `online`。
- 从 `tag:ai-ops-runner` 对端经 tailnet 访问只读 API：
  `/v1/healthz`、`/v1/inventory`、`/v1/health`、`/v1/logs` 均 200；
  `/v1/disk/smart` 在无 `smartctl` 的容器里返回结构化 `error` 而非崩溃；
  `POST /v1/exec` 需 `{"template_id","param","value"}`，模板外请求返回 400。
- 两种 key 都通过：**带 tag 的 preauthkey + agent 空 tags** 是推荐主路径；
  不带 tag 的 preauthkey 也能注册，只是节点不会有 `tag:lanhc-agent`。

### 6.6 2026-10-03 联调修复（必读）

- **容器缺 CA 证书 ⇒ 模型请求全部失败**。`node:*-slim` 没有 `/etc/ssl/certs`，
  Codex 用 rustls 校验 TLS，会只报 `error sending request`。
  `ops-runner/Dockerfile` 已加 `ca-certificates`；自定义镜像必须保留。
- **worker 自行取证**。非官方 provider（`huayu-v2`）在 Responses API 下无法按
  裸工具名调用 MCP（返回 `unsupported call`）。`worker/collect.js` 直接在 worker
  内驱动 `mcp-lanhc` 的只读 handler，把结构化证据塞进 prompt，模型只做推理；
  Codex 内 MCP 工具退化为可选能力。全部工具已带 `readOnlyHint`，避免审批弹窗。
- **诊断必须来自 `agent_message`**。`codex exec --json` 会输出 JSONL；
  `worker/lib.js` 只解析最后一条 `agent_message` 的 JSON，缺字段则降级并标注。
- **凭据变更要重写 config**。`ensureCodexHome()` 每次启动重写
  `[mcp_servers.lanhc.env]`；`auth.json` 由 `OPENAI_API_KEY` 生成。
  缺 key 时 worker 直接失败，不再空转到 600s 超时。
- **卡死 run 回收**。`AIOPS_STALE_RUN_MS`（默认 10 分钟）把超时仍 `running` 的
  run 标记 `failed`；`AIOPS_REAP_ANY=1` 时也回收其它 worker 的遗留 run。
- **命名**：控制台 = `Lanhc AI Console` / 蓝核AI智控台；AI 模块 = `Lanhc Sentinel` /
  蓝核哨兵，路由仍在 `/ai-ops/*`。

关键坑：

- **preauth key 已是 tagged** 时，客户端不要再请求同一 tag：headscale v0.29 会拒绝
  `requested tags [...] are invalid or not permitted`。`lanhc-agent` 默认
  `-tags` 为空，tag 由 preauthkey 下发；若确实要手动指定，两边不要重复。
- WSL 里 `tsnet`/`lanhcd` 用 `--tun=userspace-networking`；同机访问另一节点
  `100.64.x.y` 需走 SOCKS5 转发，生产环境由真实 TUN 直接路由，不涉及此限制。

## 7. 回滚与安全

- 全部 AI 组件都是增量部署：关掉 `ops-runner` worker 即回到人工运维。
- 关掉 `AIOPS_SCHEDULER=1` 即停止自动建 incident。
- `mcp-lanhc` 只有只读工具；`lanhc-agent` 只接受模板命令；写动作必须审批。
- 生产严禁 Codex `--dangerously-bypass-approvals-and-sandbox`。
- 所有 hub 写操作已进 `audit_log`。

## 8. 常见问题

- **SSE 收不到进度**：确认请求带 `?token=`，且 nginx 关闭 SSE 缓冲
  （后端已带 `X-Accel-Buffering: no`；NPM 反代若还缓冲，需在 location 关闭 buffering）。
- **worker claim 后卡住**：确认 Codex 可出网到模型 endpoint，且
  `CODEX_HOME` 的 config 已注册 `mcp-lanhc`。
- **扫描报权限**：调度器 token 必须是 admin scope。
- **SQLite 批量写入报错**：遥测已改为逐条写入，见 `internal/ai-ops/telemetry.js`。
