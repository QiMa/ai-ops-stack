# lanhc AI-Ops 一键部署栈

- `hub`：lanhc-hub 控制台 + ai-ops API，管理端口 `3081`。
- `ops-runner`：Codex worker，镜像内置 Codex CLI 与 mcp-lanhc，消费 hub 的 `ai_ops_run` 队列。

## 前置条件

- 已构建过前端静态资源（hub 镜像会 COPY `lanhc-hub/frontend/dist`）：
  ```bash
  cd /home/dev/src/lanhc-hub/frontend
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

## 注意

- `AIOPS_HUB_URL=http://hub:3000` 是容器内网地址；直连后端端口 3000，
  不经 nginx。worker 的 `request()` 会自行拼接 `/ai-ops/...`，因此不要带 `/api`。
  通过宿主机/nginx 访问时才使用 `http://localhost:3081/api`。
- `hub` 的 nginx 管理端口 `81` 对外映射为 `3081`，浏览器控制台入口
  `http://localhost:3081`。
- `ops-runner` 镜像内置 Codex CLI（默认 `@openai/codex@0.159.3`）和
  `mcp-lanhc`，不再从宿主机挂载源码；如需改版本，改 `ops-runner/Dockerfile` 的
  `CODEX_VERSION`。
- headscale / lanhc-agent 不在本栈内，需要已有 tailnet。
- 生产多副本：只让一个 hub 开 `AIOPS_SCHEDULER=1`。
