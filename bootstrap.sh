#!/usr/bin/env bash
# 一行启动引导：装依赖 → 取代码 → 跑主流程 → 自动关机。
#
# 设计目标：pod 里【不需要任何环境变量】除凭证外；
# 目标、子树、并发、看门狗全部由 run.sh 内置默认值决定。
#
# 幂等：重复执行时若 /app/run.sh 已存在就复用它，不重新克隆
#       （避免 git clone 到非空目录报 "destination path already exists"）。
#
# 可用环境变量覆盖（都不必设）:
#   LCM_REPO_URL  代码仓库（默认下面的）
#   LCM_REF       分支/标签（默认 main）
#   GITHUB_TOKEN  上传结果用（别名 LCM_GH_TOKEN / GH_TOKEN）
#   FEISHU_WEBHOOK / FEISHU_SECRET  飞书通知

set -o pipefail

REPO_URL="${LCM_REPO_URL:-https://github.com/lxingrui/lean-cone-measure.git}"
REF="${LCM_REF:-main}"
APP=/app

echo "===== 引导 $(date -u +%Y-%m-%dT%H:%M:%SZ) ====="
echo "仓库: $REPO_URL  分支: $REF"

# 幂等：已有代码就直接跑
if [ -f "$APP/run.sh" ]; then
  echo "代码已存在（$APP/run.sh），跳过克隆"
else
  if ! command -v git >/dev/null 2>&1; then
    echo "安装 git / ca-certificates …"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends git ca-certificates
  fi
  rm -rf "$APP"
  echo "克隆代码 …"
  git clone --depth 1 --branch "$REF" "$REPO_URL" "$APP" || {
    echo "!! 克隆失败，无法继续" >&2; exit 1; }
fi

echo "开始主流程（目标与并发由 run.sh 默认值决定）"
exec bash "$APP/run.sh" all
