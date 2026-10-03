#!/usr/bin/env bash
# AI-Ops 全栈固定版本号发布编排：用同一个 TAG 串起所有控制面镜像。
#
# 用法：
#   ./deploy/build-all.sh 20261004 [--push] [--release /path/lanhc_linux_amd64.tar.gz]
#
# 依次调用各产品仓库的 deploy/build-push.sh：
#   headscale         -> ccr.ccs.tencentyun.com/lucky/headscale:TAG
#   lanhc-hub         -> ccr.ccs.tencentyun.com/lucky/headscale-ui:TAG
#   ops-runner        -> ccr.ccs.tencentyun.com/lucky/lanhc-ops-runner:TAG
#                        ccr.ccs.tencentyun.com/lucky/lanhc-agent-host:TAG
#                        ccr.ccs.tencentyun.com/lucky/lanhc-tailnet-sidecar:TAG
#
# 本栈只负责编排，不重复定义构建参数。可用 SRC_ROOT 覆盖仓库根目录。
#
# 注意：ops-runner 的 agent/sidecar 镜像需要 lanhc 发行包二进制，加
#   --release 透传给 ops-runner。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_ROOT="${SRC_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

TAG=""
PUSH=0
RELEASE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --push) PUSH=1 ;;
    --release) RELEASE="${2:-}"; shift ;;
    -*) echo "未知参数: $1" >&2; exit 2 ;;
    *) TAG="$1" ;;
  esac
  shift
done
TAG="${TAG:-$(date +%Y%m%d)}"

PUSH_ARG=""
[ "$PUSH" = "1" ] && PUSH_ARG="--push"

set -x
"$SRC_ROOT/headscale/deploy/build-push.sh" "$TAG" $PUSH_ARG
"$SRC_ROOT/lanhc-hub/deploy/build-push.sh" "$TAG" $PUSH_ARG

RUNNER_ARGS=("$TAG")
[ -n "$PUSH_ARG" ] && RUNNER_ARGS+=("$PUSH_ARG")
[ -n "$RELEASE" ] && RUNNER_ARGS+=(--release "$RELEASE")
"$SRC_ROOT/ops-runner/deploy/build-push.sh" "${RUNNER_ARGS[@]}"
set +x

echo "✅ AI-Ops 全栈镜像已构建，TAG=${TAG}"
