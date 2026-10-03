# lanhc AI-Ops 一键部署栈

- `hub`：hs-console 控制台 + ai-ops API，管理端口 `3081`。
- `ops-runner`：Codex worker，镜像内置 Codex CLI 与 mcp-lanhc，消费 hub 的 `ai_ops_run` 队列。

## 前置条件

- 已构建过前端静态资源（hub 镜像会 COPY `hs-console/frontend/dist`）：
  ```bash
  cd /home/dev/src/hs-console/frontend
  NODE_OPTIONS=--openssl-legacy-provider yarn build
  ```
- 已有可访问的 headscale，并准备只读 API key。
- 已部署 lanhc-agent（设备侧）和/或 iDRAC/Redfish 带外地址。

## 启动

```bash
cd /home/dev/src/ai-ops-stack
cp .env.example .env
# 编辑 .env 填真实凭据
docker compose up -d --build
```

## 验证

```bash
# hub API 存活
curl -s http://localhost:3081/api | jq

# worker 日志
docker compose logs -f ops-runner

# worker 自检（镜像内置，无需宿主机 Codex）
docker compose run --rm --no-deps ops-runner node /workspace/ops-runner/worker/worker.js --self-test
```

## 常见坑（2026-10-03 联调）

- **模型请求全部失败 / 一直转圈**：`node:*-slim` 基础镜像没有 `/etc/ssl/certs`，
  Codex（rustls）会只报 `error sending request`。`ops-runner/Dockerfile` 已安装
  `ca-certificates`，自定义镜像务必保留。
- **诊断内容像是 shell 文本**：说明 worker 没取到最后一条 `agent_message`。
  现在由 `worker/collect.js` 先取证、`worker/lib.js` 只解析 `agent_message`。
- **改凭据后没生效**：`codex-home` 是持久化 volume，worker 每次启动都会重写
  `[mcp_servers.lanhc.env]`。若仍异常，可 `docker compose down -v` 后重建。
- **run 卡在 running**：`AIOPS_STALE_RUN_MS`（默认 10 分钟）会自动回收；
  单机部署可设 `AIOPS_REAP_ANY=1` 连其它 worker 的遗留 run 一起收。

## 发布（固定版本号）

全栈镜像统一用日期式 TAG（如 `20261004`），一条命令出全量 tag：

```bash
cd /home/dev/src/ai-ops-stack

# 本地构建，不推送（全部打 :local 别名，先 compose 验收）
./deploy/build-all.sh 20261004

# 构建并推送五个 CCR 镜像
./deploy/build-all.sh 20261004 --push

# agent/sidecar 需要 lanhc 发行包时，从 tar.gz 自动取二进制
./deploy/build-all.sh 20261004 --push --release /home/dev/out/lanhc/lanhc_linux_amd64.tar.gz
```

会依次产出同一 TAG：

- `ccr.ccs.tencentyun.com/lucky/headscale:20261004`
- `ccr.ccs.tencentyun.com/lucky/hs-console:20261004`
- `ccr.ccs.tencentyun.com/lucky/lanhc-ops-runner:20261004`
- `ccr.ccs.tencentyun.com/lucky/lanhc-agent-host:20261004`
- `ccr.ccs.tencentyun.com/lucky/lanhc-tailnet-sidecar:20261004`

单产品发版直接进对应仓库：

```bash
./deploy/build-push.sh <TAG> [--push]     # hs-console / headscale / ops-runner / lanhc-hugo
./deploy/build-push.sh [<TAG>] [--no-upload]  # lanhc（发行包发布，默认自动递增 +lanhcN）
```

`build-all.sh` 只是编排层，不重复定义构建参数；默认 `SRC_ROOT=/home/dev/src`。

## 命名

- 控制台：`Lanhc AI Console` / 蓝核AI智控台
- AI 模块：`Lanhc Sentinel` / 蓝核哨兵（路由仍是 `/ai-ops/*`）

## 注意

- `AIOPS_HUB_URL=http://hub:3000` 是容器内网地址；直连后端端口 3000，
  不经 nginx。worker 的 `request()` 会自行拼接 `/ai-ops/...`，因此不要带 `/api`。
  通过宿主机/nginx 访问时才使用 `http://localhost:3081/api`。
- `hub` 的 nginx 管理端口 `81` 对外映射为 `3081`，浏览器控制台入口
  `http://localhost:3081`。
- `ops-runner` 镜像内置 Codex CLI（默认 `@openai/codex@0.159.3`）和
  `mcp-lanhc`，不再从宿主机挂载源码；如需改版本，改 `ops-runner/Dockerfile` 的
  `CODEX_VERSION`。
- SMART 遥测默认关闭；置 `AIOPS_TELEMETRY_ENABLED=1` 后 worker 会定时采集
  agent 节点磁盘指标并推给 hub（详情见 `docs/AI-OPS-DEPLOY-RUNBOOK.md` 5.3）。
- headscale / lanhc-agent 不在本栈内，需要已有 tailnet。
- 生产多副本：只让一个 hub 开 `AIOPS_SCHEDULER=1`。
