# AGENTS.md — ai-ops-stack

## 定位
lanhc AI-Ops 一键部署栈：`hub`（hs-console + ai-ops API，端口 `3081`）+
`ops-runner`（Codex worker，消费 `ai_ops_run` 队列）。

## 约定
- 分支 `main`，远程 `origin` = `git@github.com:QiMa/ai-ops-stack.git`。
- `.env`、`*.log` 不入库（见 `.gitignore`）；真实凭据只放本地 `.env`。
- 全栈镜像统一日期 TAG `YYYYMMDD`：`./deploy/build-all.sh <TAG> [--push]`，
  镜像前缀 `ccr.ccs.tencentyun.com/lucky/`。
- `build-all.sh` 是编排层，不重复定义构建参数；`SRC_ROOT=/home/dev/src`。
- hub 镜像依赖 `hs-console/frontend/dist` 已构建；`ops-runner` 镜像内置 Codex。
- 生产多副本只让一个 hub 开 `AIOPS_SCHEDULER=1`。
- 文档随代码更新，`docs/` 下记录部署/联调/rollout 事实（提交风格 `docs(ai-ops): ...`）。

## 关系
- 编排 `hs-console`、`ops-runner`、`headscale`、`lanhc-agent`；headscale 不在本栈内。
