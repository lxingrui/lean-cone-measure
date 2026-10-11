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
# 环境变量带 LCM_ 前缀可避免与其它项目串味（RunPod 的 Secrets 是账号级的）。
# 同时兼容几种常见命名，按优先级取：
#   token  : LCM_GH_TOKEN > GITHUB_TOKEN > GH_TOKEN
#   webhook: LCM_FEISHU_WEBHOOK > FEISHU_WEBHOOK
GH_TOKEN="${LCM_GH_TOKEN:-${GITHUB_TOKEN:-${GH_TOKEN:-}}}"
FEISHU_WEBHOOK="${LCM_FEISHU_WEBHOOK:-${FEISHU_WEBHOOK:-}}"
FEISHU_SECRET="${LCM_FEISHU_SECRET:-${FEISHU_SECRET:-}}"
OAI_SUBTREE="${LCM_OAI_SUBTREE:-${OAI_SUBTREE:-}}"
# TARGET 可从 OAI_SUBTREE 推断：给了子树即视为要测 OAI
TARGET="${LCM_TARGET:-${TARGET:-$([ -n "$OAI_SUBTREE" ] && echo oai || echo mathlib)}}"
# 以下都非机密，脚本内有默认值，无需设置
GH_REPO="${LCM_GH_REPO:-${GH_REPO:-lxingrui/lean-cone-measure}}"
OAI_FULL="${LCM_OAI_FULL:-${OAI_FULL:-0}}"
LCM_PUSH_REFS="${LCM_PUSH_REFS:-${PUSH_REFS:-0}}"
RESULT_BRANCH="${LCM_RESULT_BRANCH:-${RESULT_BRANCH:-results}}"
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

# 阶段留痕：把进度写进 results/，即使 Pod 被 Max Runtime 强杀（容器盘一起消失），
# 只要之前某次 upload 成功过，仓库里就有"最后推进到哪一步"的记录。
mark_progress() {
  local name="$1" state="$2"
  mkdir -p "$RES"
  printf '{"stage":"%s","state":"%s","at":"%s","elapsed_seconds":%s}\n' \
    "$name" "$state" "$(ts)" "$(elapsed)" > "$RES/progress.json"
  # 尽力而为地上传，失败不影响主流程
  do_upload >/dev/null 2>&1 || true
}

run_logged() {
  local name="$1"; shift
  local t0; t0=$(date +%s)
  say "==> $name"
  if ! "$@" 2>&1 | tee -a "$LOGS/$name.log"; then
    local d=$(( $(date +%s) - t0 ))
    mark_progress "$name" failed
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
  mark_progress "$name" done
}

# ---------- 自动关机 ----------
# 跑完自动关掉 pod，避免空转计费。
#
# 机制参考 OpenAI 的 parameter-golf/scripts/pod_selfterm.py：
#   1) 调 RunPod API 删除 pod（需要 RUNPOD_API_KEY）
#   2) 失败则 kill 1 —— 杀 PID 1，RunPod 据此停止 pod（不需要任何 key）
#
# RUNPOD_POD_ID 由 RunPod 运行时【自动注入】，无需手动设置。
# 环境变量:
#   RUNPOD_API_KEY  可选；不设则跳过 API 删除，直接走 kill 1
#   LCM_SELFTERM    设为 0 可关闭自动关机（调试时有用）
selfterm() {
  local need_fallback=1
  local pod_id="${RUNPOD_POD_ID:-}"
  local api_key="${RUNPOD_API_KEY:-}"

  if [ "${LCM_SELFTERM:-1}" = "0" ]; then
    say "LCM_SELFTERM=0，跳过自动关机（pod 继续运行，记得手动删）"
    return 0
  fi

  if [ -n "$api_key" ] && [ -n "$pod_id" ]; then
    say "自动关机：调用 RunPod API 删除 pod $pod_id"
    local code
    code=$(curl -sS -o /tmp/runpod_del.txt -w '%{http_code}' --max-time 30 \
      -X DELETE "https://rest.runpod.io/v1/pods/${pod_id}" \
      -H "Authorization: Bearer ${api_key}" 2>/dev/null || echo 000)
    say "  API 返回 HTTP $code  $(head -c 200 /tmp/runpod_del.txt 2>/dev/null)"
    case "$code" in 200|204) need_fallback=0 ;; esac
  else
    say "自动关机：未设 RUNPOD_API_KEY（或 POD_ID 为空），走 kill 1 兜底"
  fi

  [ $need_fallback -ne 0 ] && say "自动关机：kill 1（让容器主进程退出）"
  sync
  sleep 3
  kill 1 2>/dev/null || true
}

# ---------- 环境自检 ----------
preflight() {
  say "环境: ${VCPU} vCPU, $(free -g | awk '/^Mem:/{print $2}') GB RAM, 容器盘 $(df -BG / | awk 'NR==2{print $2}')"
  df -BG / | awk 'NR==2{print "     可用磁盘: "$4}'
  AVAIL_GB=$(df -BG / | awk 'NR==2{gsub("G","",$4); print $4}')
  say "并发 JOBS=$JOBS（可用 JOBS=N 覆盖）"

  # 全量编译 OAI：不禁止，但必须显式确认 + 给出真实数字
  if [ "$TARGET" = "oai" ] && [ -z "$OAI_SUBTREE" ]; then
    say "────────────────────────────────────────────────"
    say "目标 = 整个 OAI 库（未指定 OAI_SUBTREE）"
    say "  源码        : ~1.5 GB / 122,000 个 .lean 文件"
    say "  编译产物估算: 80–100 GB（按本机 mathlib 的 65x 比例外推）"
    say "  预计耗时    : 10–25 小时（8 vCPU）"
    say "  当前可用磁盘: ${AVAIL_GB} GB"
    say "  作者提示    : lean/README.md 说全量编译可能失败，建议只编译小部分"
    say "────────────────────────────────────────────────"
    if [ "$OAI_FULL" != "1" ]; then
      die "拒绝擅自全量编译。确认要跑请加环境变量 OAI_FULL=1；否则请指定 OAI_SUBTREE=OAI/<领域>"
    fi
    if [ "$AVAIL_GB" -lt 110 ]; then
      die "磁盘 ${AVAIL_GB}G 不足（全量编译需 80–100 GB 产物）。请加大容器盘，或改用 OAI_SUBTREE"
    fi
    say "OAI_FULL=1 已确认，继续全量编译"
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
  say "汇总成可喂 AI 的报告"
  node "$APP/build_report.mjs" "$RES/measures.jsonl" "$RES" "${TARGET}${OAI_SUBTREE:+ $OAI_SUBTREE}" "$PROJ" || say "⚠️ 报告生成失败（不影响 measures.jsonl）"
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

  # 压缩要上传的大文件
  [ -f "$RES/measures.jsonl" ] && [ ! -f "$RES/measures.jsonl.gz" ] && gzip -9 -f "$RES/measures.jsonl" || true
  # refs.tsv（带权图）是中间产物：大领域约 1.9 GB、全量约 4.8 GB，即使 gzip 也不该进 git。
  # 要它就在 Pod 上手取，或设 LCM_PUSH_REFS=1 强行推（小族才建议）。
  if [ "$LCM_PUSH_REFS" = "1" ]; then
    [ -f "$RES/refs.tsv" ] && gzip -9 -f "$RES/refs.tsv" || true
  else
    say "跳过 refs.tsv（中间产物，避免撑爆仓库）——要它请设 LCM_PUSH_REFS=1"
  fi

  # 体积守卫：GitHub 单文件 100 MiB 会拒绝，>50 MiB 会告警
  say "上传前体积检查:"
  EXCLUDE=""
  if ! node "$APP/sizeguard.mjs" "$RES" $([ "$LCM_PUSH_REFS" = "1" ] && echo --refs); then
    EXCLUDE="measures.jsonl.gz"      # 超限则排除最重的那个，保住 summary.json
    say "⚠️ measures 超限，本次只推 summary.json + logs"
  fi

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
  # 暂存目录：只放要推的文件（超限的排除在外）
  STAGE="/tmp/stage"
  rm -rf "$STAGE"; mkdir -p "$STAGE/results" "$STAGE/logs"
  for f in "$RES"/*; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    if [ -n "$EXCLUDE" ] && [ "$base" = "$EXCLUDE" ]; then
      say "  排除 $base（超体积上限，仅留在容器内）"
      continue
    fi
    cp -r "$f" "$STAGE/results/" 2>/dev/null || true
  done
  cp -r "$LOGS"/. "$STAGE/logs/" 2>/dev/null || true

  BRANCH="$RESULT_BRANCH"
  REMOTE="https://x-access-token:${GH_TOKEN}@github.com/${GH_REPO}.git"

  cd "$STAGE"
  git init -q
  git config user.email "measure-bot@localhost"
  git config user.name "lean-cone-measure bot"
  git checkout -q -b "$BRANCH"

  if git ls-remote --exit-code --heads "$REMOTE" "$BRANCH" >/dev/null 2>&1; then
    say "分支 $BRANCH 已存在，合并历史以保留之前的进度记录"
    mkdir -p /tmp/prev
    if git -C /tmp/prev init -q 2>/dev/null &&
       git -C /tmp/prev remote add origin "$REMOTE" 2>/dev/null || true; then
      git -C /tmp/prev fetch -q --depth 1 origin "$BRANCH" 2>/dev/null &&
        git -C /tmp/prev checkout -q FETCH_HEAD 2>/dev/null || true
      # 只补不覆盖：把上一次的记录加进来，本次结果优先
      [ -d /tmp/prev/results ] && cp -rn /tmp/prev/results/. "$STAGE/results/" 2>/dev/null || true
      [ -d /tmp/prev/logs ]    && cp -rn /tmp/prev/logs/.    "$STAGE/logs/"    2>/dev/null || true
    fi
  fi

  git add -f results logs 2>/dev/null || true
  git commit -q -m "measure: ${TARGET}${OAI_SUBTREE:+ $OAI_SUBTREE} @ $(ts)" || say "无变更可提交"
  git push -q --force "$REMOTE" "$BRANCH"
  say "已推送到 ${GH_REPO} 的 ${BRANCH} 分支"
  ls -la "$RES"
}

# ---------- 调度 ----------
START_EPOCH=$(date +%s)

# 看门狗：即使主流程卡死（编译挂住、网络卡住），到点也强制关机。
# 默认 14 小时，可用 LCM_DEADLINE_HOURS 调整。设 0 关闭。
DEADLINE_H="${LCM_DEADLINE_HOURS:-14}"
if [ "$DEADLINE_H" != "0" ] && [ "${LCM_SELFTERM:-1}" != "0" ]; then
  ( sleep $(( DEADLINE_H * 3600 ))
    echo "[看门狗] 超过 ${DEADLINE_H}h 仍未结束，强制关机" >> "$LOGS/watchdog.log"
    RUNPOD_API_KEY="${RUNPOD_API_KEY:-}" RUNPOD_POD_ID="${RUNPOD_POD_ID:-}" \
      LCM_SELFTERM=1 bash -c "$(declare -f selfterm); selfterm" >> "$LOGS/watchdog.log" 2>&1
  ) &
  WATCHDOG_PID=$!
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] 看门狗已武装: ${DEADLINE_H}h 后强制关机 (pid $WATCHDOG_PID)" | tee -a "$LOGS/watchdog.log"
fi

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
自动关机: 跑完即关；卡死则 ${DEADLINE_H}h 后强制关"

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
结果: https://github.com/${GH_REPO:-?}/tree/${RESULT_BRANCH:-results}
pod 即将自动关机" \
        "$RES/summary.json"
    else
      notify fail "lean-cone-measure 未完成" \
        "目标: ${TARGET}${OAI_SUBTREE:+ / $OAI_SUBTREE}
已用: $(fmt_dur "$(elapsed)")
日志: https://github.com/${GH_REPO:-?}/tree/${RESULT_BRANCH:-results}/logs
pod 即将自动关机（失败也关，不空转计费）"
    fi

    # 收工关机：无论成功失败都关，避免空转
    [ -n "${WATCHDOG_PID:-}" ] && kill "$WATCHDOG_PID" 2>/dev/null || true
    selfterm
    exit $FAILED
    ;;
  *) die "未知阶段: $PHASE（可用: toolchain|deps|build|measure|upload|all）" ;;
esac
