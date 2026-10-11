#!/usr/bin/env bash
# 一次性测量任务的入口。阶段化 + 幂等：任何阶段失败后重跑会跳过已完成阶段。
#
# 设计前提：仓库里只有几十 KB 文本。
# Lean 工具链、mathlib、42 个依赖 —— 全部在【pod 上】现拉（RunPod 出网免费，不占本地流量）。
#
# 用法: run.sh [toolchain|deps|build|measure|upload|all]
#
# ⚠️ 本脚本只从【环境变量】读凭证，绝不写入任何文件。
#    需要: GH_TOKEN, GH_REPO（见 RUNBOOK §3）

set -euo pipefail

PHASE="${1:-all}"
WORK="${WORK:-/work}"
APP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RES="$APP/results"
LOGS="$APP/logs"
mkdir -p "$RES" "$LOGS" "$WORK"

# ---------- 可调参数 ----------
TARGET="${TARGET:-mathlib}"                     # mathlib | oai
OAI_SUBTREE="${OAI_SUBTREE:-}"                  # TARGET=oai 时强烈建议指定，例如 OAI/Analysis/Fourier
LEAN_TOOLCHAIN="${LEAN_TOOLCHAIN:-leanprover/lean4:v4.34.1}"   # 与 OAI 仓库 lean-toolchain 一致
MATHLIB_URL="${MATHLIB_URL:-https://github.com/leanprover-community/mathlib4.git}"
# OpenAI 数学仓库（public）。已核对：本地克隆的 .git/config 里 origin 就是这个地址，
# 且实测开放匿名访问 —— pod 里不带 token 也能拉。
# 仓库规模：约 122,000 个 Lean 文件 / 1.5 GB，另有 776 篇论文 PDF（用 --filter 让 git 惰性拉取）。
OAI_URL="${OAI_URL:-https://github.com/openai/math.git}"
VCPU="$(nproc)"
JOBS="${JOBS:-$(( VCPU > 8 ? 8 : (VCPU > 2 ? VCPU - 1 : 1) ))}"
export ELAN_HOME="${ELAN_HOME:-/root/.elan}"
export PATH="$ELAN_HOME/bin:$PATH"

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
say() { echo "[$(ts)] $*"; }
die() { echo "[$(ts)] 失败: $*" >&2; exit 1; }

# 距脚本启动的秒数
elapsed() { echo $(( $(date +%s) - START_EPOCH )); }
fmt_dur() { local s=$1; printf '%dm%02ds' $((s/60)) $((s%60)); }

# ---------- 飞书 / 通用 webhook 通知 ----------
# 没配 FEISHU_WEBHOOK / WEBHOOK_URL 时静默跳过；通知失败绝不影响主流程。
notify() {
  local status="$1" title="$2" body="$3" detail="${4:-}"
  [ -n "${FEISHU_WEBHOOK:-}${WEBHOOK_URL:-}" ] || return 0
  command -v node >/dev/null 2>&1 || { say "（无 node，跳过通知）"; return 0; }
  node "$APP/notify.mjs" "$status" "$title" "$body" "$detail" 2>&1 | tail -3 || true
}

run_logged() {
  local name="$1"; shift
  local t0; t0=$(date +%s)
  say "==> $name"
  if ! "$@" 2>&1 | tee -a "$LOGS/$name.log"; then
    local d=$(( $(date +%s) - t0 ))
    notify fail "lean-cone-measure 失败" \
      "阶段: $name
耗时: $(fmt_dur $d)（累计 $(fmt_dur "$(elapsed)")）
目标: ${TARGET}${OAI_SUBTREE:+ $OAI_SUBTREE}
主机: $(hostname)

最近日志:
$(tail -n 12 "$LOGS/$name.log" 2>/dev/null || echo '(无日志)')"
    die "$name 阶段失败，详见 logs/$name.log"
  fi
  local d=$(( $(date +%s) - t0 ))
  notify ok "阶段完成: $name" \
    "耗时: $(fmt_dur $d)（累计 $(fmt_dur "$(elapsed)")）
目标: ${TARGET}${OAI_SUBTREE:+ $OAI_SUBTREE}"
}

# ---------- 环境自检 ----------
preflight() {
  say "环境: ${VCPU} vCPU, $(free -g | awk '/^Mem:/{print $2}') GB RAM, 容器盘 $(df -BG / | awk 'NR==2{print $2}')"
  df -BG / | awk 'NR==2{print "     可用磁盘: "$4}'
  AVAIL_GB=$(df -BG / | awk 'NR==2{gsub("G","",$4); print $4}')
  say "并发 JOBS=$JOBS（可用 JOBS=N 覆盖）"
  if [ "$TARGET" = "oai" ] && [ -z "$OAI_SUBTREE" ]; then
    say "⚠️  TARGET=oai 但未指定 OAI_SUBTREE —— 会尝试全量编译"
    say "⚠️  按 65x 外推约需 100 GB，且作者自己在 lean/README.md 里说全量编译可能失败"
    if [ "$AVAIL_GB" -lt 120 ]; then die "磁盘不足(${AVAIL_GB}G)，拒绝全量编译"; fi
  fi
}

# ---------- 阶段 0：在 pod 上装 Lean 工具链（约 3 GB，pod 侧流量不计费）----------
do_toolchain() {
  if command -v lean >/dev/null 2>&1 && command -v lake >/dev/null 2>&1; then
    say "Lean 已在 PATH，跳过安装: $(lean --version)"
    return 0
  fi
  say "安装基础包（curl/git/build-essential/libgmp/libssl）"
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends \
      ca-certificates curl git build-essential libgmp-dev libssl-dev pkg-config \
      zstd xz-utils jq python3
  else
    say "⚠️ 没有 apt-get，假设基础包已存在"
  fi

  say "安装 elan + $LEAN_TOOLCHAIN（下载约 1.5–2 GB）"
  curl -fsSL https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh -o /tmp/elan-init.sh
  sh /tmp/elan-init.sh -y --default-toolchain "$LEAN_TOOLCHAIN"
  rm -f /tmp/elan-init.sh
  export PATH="$ELAN_HOME/bin:$PATH"
  hash -r
  lean --version || die "lean 安装后仍不可用"
  lake --version

  # Node：只在后处理用得上（算三个量）。优先 apt，避免拉 NodeSource。
  if ! command -v node >/dev/null 2>&1; then
    say "安装 nodejs（后处理用）"
    if command -v apt-get >/dev/null 2>&1; then
      apt-get install -y -qq --no-install-recommends nodejs || say "apt 装 nodejs 失败"
    fi
  fi
  command -v node >/dev/null 2>&1 && node --version || say "⚠️ 没有 node，后处理阶段会失败"
  say "toolchain 阶段完成"
}

# ---------- 阶段 1：拉目标库与依赖（pod 侧流量）----------
do_deps() {
  cd "$WORK"
  if [ "$TARGET" = "mathlib" ]; then
    if [ ! -d "$WORK/mathlib4/.git" ]; then
      say "克隆 mathlib4（blob 过滤，先省带宽，lake 会在需要时拉全）"
      git clone --filter=blob:none "$MATHLIB_URL" mathlib4
    else
      say "mathlib4 已存在，跳过克隆"
    fi
    cd "$WORK/mathlib4"
    say "mathlib4 commit: $(git rev-parse HEAD)"
  else
    if [ ! -d "$WORK/oai/.git" ]; then
      say "克隆 OpenAI 数学仓库（约 1.5 GB，pod 侧流量）"
      git clone --filter=blob:none "$OAI_URL" oai
    else
      say "oai 已存在，跳过克隆"
    fi
    cd "$WORK/oai"
    say "oai commit: $(git rev-parse HEAD)"
    cd lean
    say "lake update：拉 42 个依赖 + 自动打 24 个兼容补丁"
    lake update
  fi
  say "deps 阶段完成"
}

# ---------- 阶段 2：编译 ----------
do_build() {
  if [ "$TARGET" = "mathlib" ]; then
    cd "$WORK/mathlib4"
    say "拉 mathlib 预编译缓存（若失败则要自行编译，1–3 小时）"
    lake exe cache get || say "⚠️ 缓存拉取失败，将自行编译"
    say "编译 Mathlib 根模块，-j $JOBS"
    lake build Mathlib -j "$JOBS"
  else
    cd "$WORK/oai/lean"
    say "先确保 pinned mathlib 的缓存落地"
    ( cd .lake/packages/mathlib && lake exe cache get ) || say "⚠️ mathlib 缓存失败，将自行编译"
    if [ -n "$OAI_SUBTREE" ]; then
      TGT="$(echo "$OAI_SUBTREE" | sed 's#/#.#g')"
      say "只编译子树 $TGT，-j $JOBS"
      lake build "$TGT" -j "$JOBS"
    else
      say "编译整个 OAI 库，-j $JOBS（不推荐）"
      lake build OAI -j "$JOBS"
    fi
  fi
  say "build 完成，产物: $(du -sh "$PWD/.lake/build" 2>/dev/null | cut -f1)"
}

# ---------- 阶段 3：测量 ----------
do_measure() {
  TSV="$RES/refs.tsv"
  if [ "$TARGET" = "mathlib" ]; then
    PROJ="$WORK/mathlib4"; ROOT_MODULE="Mathlib"
  else
    PROJ="$WORK/oai/lean"; ROOT_MODULE="OAI"
    [ -n "$OAI_SUBTREE" ] && ROOT_MODULE="$(echo "$OAI_SUBTREE" | sed 's#/#.#g')"
  fi
  say "抽取 elaboration 后的 .const 引用（根模块 $ROOT_MODULE）"
  cd "$PROJ"
  cp "$APP/measure.lean" "$PROJ/MeasureRefs.lean"
  sed -i "s#^import Mathlib\$#import $ROOT_MODULE#" "$PROJ/MeasureRefs.lean"
  sed -i "s#OUT_PATH_PLACEHOLDER#$TSV#" "$PROJ/MeasureRefs.lean"
  sed -i "s#\`Mathlib\$\#\`$ROOT_MODULE#" "$PROJ/MeasureRefs.lean"
  lake env lean "$PROJ/MeasureRefs.lean"
  [ -s "$TSV" ] || die "refs.tsv 为空，抽取失败"

  say "后处理：算 depth / unwrapped / wrapped"
  node "$APP/post.mjs" "$TSV" "$RES"
  say "measure 阶段完成"
}

# ---------- 阶段 4：上传（失败也要尽量传）----------
do_upload() {
  if [ "${SKIP_UPLOAD:-0}" = "1" ]; then say "SKIP_UPLOAD=1，跳过上传"; return 0; fi
  [ -n "${GH_TOKEN:-}" ] || die "缺少 GH_TOKEN（只调试请设 SKIP_UPLOAD=1）"
  [ -n "${GH_REPO:-}" ] || die "缺少 GH_REPO"

  node -e '
    const fs=require("fs"),os=require("os"),cp=require("child_process");
    const sh=c=>{try{return cp.execSync(c,{stdio:["ignore","pipe","ignore"]}).toString().trim()}catch{return null}};
    fs.writeFileSync("/app/results/meta.json",JSON.stringify({
      target:process.env.TARGET||"mathlib",
      subtree:process.env.OAI_SUBTREE||null,
      generated_at:new Date().toISOString(),
      cpu:{vcpu:os.cpus().length,model:(os.cpus()[0]||{}).model},
      memory_gb:Math.round(os.totalmem()/1e9),
      node:process.version,
      lean:sh("lean --version"),
      commits:{
        mathlib:sh("git -C /work/mathlib4 rev-parse HEAD"),
        oai:sh("git -C /work/oai rev-parse HEAD")
      }
    },null,1));
  ' 2>/dev/null || {
    mkdir -p "$RES"
    printf '{"target":"%s","subtree":"%s","generated_at":"%s"}\n' \
      "$TARGET" "${OAI_SUBTREE:-}" "$(ts)" > "$RES/meta.json"
  }

  [ -f "$RES/refs.tsv" ] && gzip -9 -f "$RES/refs.tsv" || true

  cd "$APP"
  git init -q 2>/dev/null || true
  git config user.email "measure-bot@localhost"
  git config user.name "lean-cone-measure bot"
  cat > .git/info/exclude <<'EOF'
*
!results/
!results/**
!logs/
!logs/**
EOF
  BRANCH="${RESULT_BRANCH:-results}"
  REMOTE="https://x-access-token:${GH_TOKEN}@github.com/${GH_REPO}.git"

  git add -f results logs 2>/dev/null || true
  if git ls-remote --exit-code --heads "$REMOTE" "$BRANCH" >/dev/null 2>&1; then
    say "分支 $BRANCH 已存在，追加提交"
    git fetch -q --depth 1 "$REMOTE" "$BRANCH"
    git checkout -q -B "$BRANCH" FETCH_HEAD
    mkdir -p results logs
    cp -r "$RES"/. results/ 2>/dev/null || true
    cp -r "$LOGS"/. logs/ 2>/dev/null || true
    git add -f results logs
  else
    say "创建分支 $BRANCH"
    git checkout -q -b "$BRANCH"
  fi
  git commit -q -m "measure: ${TARGET}${OAI_SUBTREE:+ $OAI_SUBTREE} @ $(ts)" || say "无变更可提交"
  git push -q "$REMOTE" "$BRANCH"
  say "已推送到 ${GH_REPO} 的 ${BRANCH} 分支"
  ls -la "$RES"
}

# ---------- 调度 ----------
START_EPOCH=$(date +%s)
preflight

case "$PHASE" in
  toolchain) run_logged toolchain do_toolchain ;;
  deps)      run_logged deps      do_deps ;;
  build)     run_logged build     do_build ;;
  measure)   run_logged measure   do_measure ;;
  upload)    run_logged upload    do_upload ;;
  all)
    notify start "lean-cone-measure 启动" \
      "目标: ${TARGET}${OAI_SUBTREE:+ / $OAI_SUBTREE}
主机: ${VCPU} vCPU / $(free -g | awk '/^Mem:/{print $2}') GB RAM / 盘 $(df -BG / | awk 'NR==2{print $2}')
并发: JOBS=$JOBS
Max Runtime 到点会被平台强杀 —— 本通知只表示已启动"

    # 先做一次占位上传：保证后面全崩时仓库里也有东西
    do_upload >/dev/null 2>&1 || say "首次占位上传失败（不致命，继续）"
    FAILED=0
    for st in toolchain deps build measure; do
      if ! run_logged "$st" "do_$st"; then FAILED=1; break; fi
    done
    do_upload || say "上传阶段也失败了"

    if [ $FAILED -eq 0 ]; then
      notify ok "lean-cone-measure 全部完成" \
        "目标: ${TARGET}${OAI_SUBTREE:+ / $OAI_SUBTREE}
总耗时: $(fmt_dur "$(elapsed)")
结果: https://github.com/${GH_REPO:-?}/tree/${RESULT_BRANCH:-results}" \
        "$RES/summary.json"
    else
      notify fail "lean-cone-measure 未完成" \
        "目标: ${TARGET}${OAI_SUBTREE:+ / $OAI_SUBTREE}
已用: $(fmt_dur "$(elapsed)")
日志: https://github.com/${GH_REPO:-?}/tree/${RESULT_BRANCH:-results}/logs"
    fi
    exit $FAILED
    ;;
  *) die "未知阶段: $PHASE（可用: toolchain|deps|build|measure|upload|all）" ;;
esac
