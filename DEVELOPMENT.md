# DEVELOPMENT — ai-ops-stack

通用规范（提交/分支/远程/发布/安全）以工作区权威文件为准：
`/home/dev/src/lanhc-workspace/DEVELOPMENT.md`（仓库 https://github.com/QiMa/lanhc-workspace）。
本文件只列本仓库的本地差异与命令；冲突时以本仓库为准并回填工作区规范。

## 本地命令

```bash
cp .env.example .env && docker compose up -d --build
./deploy/build-all.sh <YYYYMMDD> [--push]
```
