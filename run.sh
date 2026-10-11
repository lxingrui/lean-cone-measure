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
APP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- 工作目录在下面「选择工作目录」一节决定 ----------
# （优先系统盘本地 NVMe；系统盘不够才用网络卷）

# ---------- 可调参数 ----------
# 环境变量带 LCM_ 前缀可避免与其它项目串味（RunPod 的 Secrets 是账号级的）。
# 同时兼容几种常见命名，按优先级取：
#   token  : LCM_GH_TOKEN > GITHUB_TOKEN > GH_TOKEN
#   webhook: LCM_FEISHU_WEBHOOK > FEISHU_WEBHOOK
GH_TOKEN="${LCM_GH_TOKEN:-${GITHUB_TOKEN:-${GH_TOKEN:-}}}"
FEISHU_WEBHOOK="${LCM_FEISHU_WEBHOOK:-${FEISHU_WEBHOOK:-}}"
FEISHU_SECRET="${LCM_FEISHU_SECRET:-${FEISHU_SECRET:-}}"
OAI_SUBTREE="${LCM_OAI_SUBTREE:-${OAI_SUBTREE:-OAI/Analysis/Crouzeix}}"
# 要跑哪些目标。支持多目标顺序跑，逗号/空格分隔。
#   默认 "mathlib,oai" —— 开机就两个都跑，不需要任何环境变量
#   若显式给了 OAI_SUBTREE 但没给 TARGETS，则只跑 oai（方便单测某个子树）
_raw_targets="${LCM_TARGETS:-${TARGETS:-}}"
if [ -z "$_raw_targets" ]; then
  if [ -n "${LCM_TARGET:-${TARGET:-}}" ]; then
    _raw_targets="${LCM_TARGET:-${TARGET}}"
  else
    _raw_targets="mathlib,oai"      # 默认：两个都跑
  fi
fi
# 规范化成分隔的空格列表
TARGETS="$(echo "$_raw_targets" | tr ',' ' ' | tr -s ' ')"
# 兼容旧变量：TARGET 取列表第一个
TARGET="${TARGETS%% *}"
# 以下都非机密，脚本内有默认值，无需设置
GH_REPO="${LCM_GH_REPO:-${GH_REPO:-lxingrui/lean-cone-measure}}"
OAI_FULL="${LCM_OAI_FULL:-${OAI_FULL:-0}}"
LCM_PUSH_REFS="${LCM_PUSH_REFS:-${PUSH_REFS:-0}}"
RESULT_BRANCH="${LCM_RESULT_BRANCH:-${RESULT_BRANCH:-results}}"
# 本次运行大约需要多少工作空间（探盘与守卫共用）
# 估算依据（mathlib+oai 两个目标）：
#   mathlib 缓存解包峰值 ~7G + mathlib olean ~7G + OAI 源码 1.5G
#   + 42 个依赖源码/olean ~15G + git 对象与中间产物 ~5G
WORK_NEED_GB=60
case " $TARGETS " in *" oai "*) [ "$OAI_FULL" = "1" ] && WORK_NEED_GB=110 ;; esac
LEAN_TOOLCHAIN="${LEAN_TOOLCHAIN:-leanprover/lean4:v4.34.1}"   # 与 OAI 仓库 lean-toolchain 一致
MATHLIB_URL="${MATHLIB_URL:-https://github.com/leanprover-community/mathlib4.git}"
# OpenAI 数学仓库（public）。已核对：本地克隆的 .git/config 里 origin 就是这个地址，
# 且实测开放匿名访问 —— pod 里不带 token 也能拉。
# 仓库规模：约 122,000 个 Lean 文件 / 1.5 GB，另有 776 篇论文 PDF（用 --filter 让 git 惰性拉取）。
OAI_URL="${OAI_URL:-https://github.com/openai/math.git}"

# ---------- 工作目录：固定用系统盘 ----------
# RunPod 的 Container Disk（系统盘）是本地 NVMe，比网络卷快得多；
# 本任务结果都推 GitHub，不需要持久化，所以直接用系统盘，不用网络卷。
# 想换位置就设 LCM_WORK=<路径>。
WORK="${LCM_WORK:-/work}"
mkdir -p "$WORK" "$WORK/results" "$WORK/logs" 2>/dev/null || true
RES="$WORK/results"
LOGS="$WORK/logs"
WORK_SRC="系统盘（Container Disk）"

# 结果与日志也放工作目录
RES="$WORK/results"
LOGS="$WORK/logs"
mkdir -p "$RES" "$LOGS"
VCPU="$(nproc)"
MEM_GB="$(free -g 2>/dev/null | awk '/^Mem:/{print $2}')"
[ -z "$MEM_GB" ] && MEM_GB=16
# 并发自动定：同时看 vCPU 和内存。
#   · vCPU 上限 = min(vCPU-1, 8)
#   · 内存上限 = (内存 - 8G 给系统) / 12G 每个 Lean 进程（大文件峰值可到 8–12G）
# 例：4v/32G → min(3, (32-8)/12=2) = 2；8v/64G → min(7, 4) = 4
if [ -z "${JOBS:-}" ]; then
  JOBS_CPU=$(( VCPU > 8 ? 8 : (VCPU > 2 ? VCPU - 1 : 1) ))
  JOBS_MEM=$(( (MEM_GB - 8) / 12 ))
  [ "$JOBS_MEM" -lt 1 ] && JOBS_MEM=1
  JOBS=$(( JOBS_CPU < JOBS_MEM ? JOBS_CPU : JOBS_MEM ))
  JOBS_AUTO=1
fi
JOBS="${JOBS:-2}"
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
  say "环境: ${VCPU} vCPU, ${MEM_GB} GB RAM"
  say "工作目录: $WORK   （来源: ${WORK_SRC:-?}）"
  say "── 所有挂载点（排查网络卷挂到哪了，看这里）──"
  df -BG 2>/dev/null | awk 'NR==1{next} {printf "  %-22s 总量 %-6s 已用 %-6s 可用 %-6s 使用率 %-5s %s\n", $1, $2, $3, $4, $5, $6}'
  say "────────────────────────────────────────────────"

  AVAIL_GB=$(df -BG "$WORK" 2>/dev/null | awk 'NR==2{gsub("G","",$4); print $4}')
  ROOT_AVAIL_GB=$(df -BG / | awk 'NR==2{gsub("G","",$4); print $4}')
  AVAIL_GB="${AVAIL_GB:-0}"; ROOT_AVAIL_GB="${ROOT_AVAIL_GB:-0}"
  say "可用空间: 工作盘 ${AVAIL_GB} GB / 系统盘 ${ROOT_AVAIL_GB} GB"

  # 关键守卫：工作盘必须够大
  NEED_GB="$WORK_NEED_GB"
  if [ "$AVAIL_GB" -lt "$NEED_GB" ]; then
    say "❌ 工作盘只有 ${AVAIL_GB} GB，本次需要约 ${NEED_GB} GB"
    say ""
    say "  最可能的原因：RunPod 的【网络卷(Volume)】没有挂到这个 Pod 上。"
    say "  检查顺序："
    say "   1. 创建 Pod 时是否选了 Volume，且挂载路径是 /workspace"
    say "   2. Volume 必须在【同一个数据中心】才能挂到该 Pod"
    say "   3. 上面「所有挂载点」列表里应出现一个几十~上百 G 的卷"
    say "   4. 若卷挂在别处，设环境变量 LCM_WORK=<那个路径> 即可"
    say "   5. 或者干脆不用网络卷：把 Container Disk 直接设成 120 GB"
    say "  当前工作目录 $WORK 落在系统盘上，继续跑只会再报"
    say "  'No space left on device (os error 28)'。"
    # 不要在这里直接 die：让调用方先发飞书通知再退出
    PREFLIGHT_DISK_FAIL=1
    return 0
  fi
  PREFLIGHT_DISK_FAIL=0

  say "目标: $TARGETS${OAI_SUBTREE:+   (oai 子树=$OAI_SUBTREE)}"
  if [ "${JOBS_AUTO:-0}" = "1" ]; then
    say "并发 JOBS=$JOBS（自动：${VCPU} vCPU / ${MEM_GB} GB 内存 → 取 CPU 与内存上限的较小值；可用 JOBS=N 覆盖）"
  else
    say "并发 JOBS=$JOBS（手动指定）"
  fi

  # 常见错误：网络卷没挂上 / 没挂到 /workspace，导致在大盘上空转、把 10G 系统盘写满
  if [ "$ROOT_AVAIL_GB" -lt 25 ] && [ "$WORK" != "/" ]; then
    say "⚠️  系统盘只剩 ${ROOT_AVAIL_GB} GB。工作目录已放在 $WORK，"
    say "    但 Lean 工具链（约 3 GB）仍装在系统盘 —— 若小于 25 GB 可能不够。"
  fi
  if [ "$WORK" = "/" ] || { [ "$WORK" = "$APP/work" ] && [ "$ROOT_AVAIL_GB" -lt 60 ]; }; then
    say "────────────────────────────────────────────────"
    say "⚠️  没有找到大容量工作盘，工作目录 = $WORK（很可能就是容器/系统盘）"
    say "    RunPod 上应该把 Volume（网络卷）挂到 /workspace，"
    say "    并保证 Container Disk（系统盘）至少 25 GB 给工具链。"
    say "    否则编译产物会写满系统盘，表现为："
    say "      No space left on device (os error 28)"
    say "    也可以显式指定：LCM_WORK=/你的挂载点"
    say "────────────────────────────────────────────────"
    if [ "$AVAIL_GB" -lt 60 ]; then
      die "工作盘仅 ${AVAIL_GB} GB，装不下编译产物。请挂载网络卷到 /workspace，或设 LCM_WORK"
    fi
  fi

  # 全量编译 OAI：不禁止，但必须显式确认 + 给出真实数字
  case " $TARGETS " in
  *" oai "*)
    if [ -z "$OAI_SUBTREE" ]; then
      say "────────────────────────────────────────────────"
      say "目标含 oai 但未指定 OAI_SUBTREE —— 将编译整个 OAI 库"
      say "  源码        : ~1.5 GB / 122,000 个 .lean 文件"
      say "  编译产物估算: 80–100 GB（按本机 mathlib 的 65x 比例外推）"
      say "  预计耗时    : 10–25 小时（8 vCPU）"
      say "  当前可用磁盘: ${AVAIL_GB} GB"
      say "  作者提示    : lean/README.md 说全量编译可能失败，建议只编译小部分"
      say "────────────────────────────────────────────────"
      if [ "$OAI_FULL" != "1" ]; then
        die "拒绝擅自全量编译。确认请设 OAI_FULL=1；否则请指定 LCM_OAI_SUBTREE=OAI/<领域>"
      fi
      if [ "$AVAIL_GB" -lt 110 ]; then
        die "工作盘 ${AVAIL_GB}G 不足（全量编译需 80–100 GB）。请加大网络卷，或指定 OAI_SUBTREE"
      fi
      say "OAI_FULL=1 已确认，继续全量编译"
    fi
    ;;
  esac
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
# 参数: $1 = 目标（mathlib | oai）
do_deps() {
  local t="$1"
  cd "$WORK"
  if [ "$t" = "mathlib" ]; then
    if [ ! -d "$WORK/mathlib4/.git" ]; then
      say "[$t] 克隆 mathlib4（blob 过滤，先省带宽，lake 会在需要时拉全）"
      git clone --filter=blob:none "$MATHLIB_URL" mathlib4
    else
      say "[$t] mathlib4 已存在，跳过克隆"
    fi
    cd "$WORK/mathlib4"
    say "[$t] mathlib4 commit: $(git rev-parse HEAD)"
  else
    if [ ! -d "$WORK/oai/.git" ]; then
      say "[$t] 克隆 OpenAI 数学仓库（约 1.5 GB，pod 侧流量）"
      git clone --filter=blob:none "$OAI_URL" oai
    else
      say "[$t] oai 已存在，跳过克隆"
    fi
    cd "$WORK/oai"
    say "[$t] oai commit: $(git rev-parse HEAD)"
    cd lean
    say "[$t] lake update：拉 42 个依赖 + 自动打 24 个兼容补丁"
    lake update
  fi
  say "[$t] deps 阶段完成"
}

# ---------- 阶段 2：编译 ----------
# 参数: $1 = 目标（mathlib | oai）
do_build() {
  local t="$1"
  if [ "$t" = "mathlib" ]; then
    cd "$WORK/mathlib4"
    say "[$t] 拉 mathlib 预编译缓存（失败则要自行编译，1–3 小时）"
    lake exe cache get || say "[$t] ⚠️ 缓存拉取失败，将自行编译"
    say "[$t] 编译 Mathlib 根模块，-j $JOBS"
    lake build Mathlib -j "$JOBS"
  else
    cd "$WORK/oai/lean"
    say "[$t] 先确保 pinned mathlib 的缓存落地"
    ( cd .lake/packages/mathlib && lake exe cache get ) || say "[$t] ⚠️ mathlib 缓存失败，将自行编译"
    if [ -n "$OAI_SUBTREE" ]; then
      local TGT; TGT="$(echo "$OAI_SUBTREE" | sed 's#/#.#g')"
      say "[$t] 只编译子树 $TGT，-j $JOBS"
      lake build "$TGT" -j "$JOBS"
    else
      say "[$t] 编译整个 OAI 库，-j $JOBS（不推荐）"
      lake build OAI -j "$JOBS"
    fi
  fi
  say "[$t] build 完成，产物: $(du -sh "$PWD/.lake/build" 2>/dev/null | cut -f1)"
}

# ---------- 阶段 3：测量 ----------
# 参数: $1 = 目标（mathlib | oai）
# 产物写到 $RES/$1/ 下，这样同一台 pod 上跑多个目标不会互相覆盖
do_measure() {
  local t="$1"
  local OUTD="$RES/$t"
  mkdir -p "$OUTD"
  local TSV="$OUTD/refs.tsv"
  local PROJ ROOT_MODULE
  if [ "$t" = "mathlib" ]; then
    PROJ="$WORK/mathlib4"; ROOT_MODULE="Mathlib"
  else
    PROJ="$WORK/oai/lean"; ROOT_MODULE="OAI"
    [ -n "$OAI_SUBTREE" ] && ROOT_MODULE="$(echo "$OAI_SUBTREE" | sed 's#/#.#g')"
  fi
  say "[$t] 抽取 elaboration 后的 .const 引用（根模块 $ROOT_MODULE）"
  cd "$PROJ"
  cp "$APP/measure.lean" "$PROJ/MeasureRefs.lean"
  sed -i "s#^import Mathlib\$#import $ROOT_MODULE#" "$PROJ/MeasureRefs.lean"
  sed -i "s#OUT_PATH_PLACEHOLDER#$TSV#" "$PROJ/MeasureRefs.lean"
  sed -i "s#\`Mathlib\$\#\`$ROOT_MODULE#" "$PROJ/MeasureRefs.lean"
  lake env lean "$PROJ/MeasureRefs.lean"
  [ -s "$TSV" ] || die "[$t] refs.tsv 为空，抽取失败"

  say "[$t] 后处理：算 depth / unwrapped / wrapped"
  node "$APP/post.mjs" "$TSV" "$OUTD"
  say "[$t] 汇总成可喂 AI 的报告"
  node "$APP/build_report.mjs" "$OUTD/measures.jsonl" "$OUTD" "${t}${OAI_SUBTREE:+ $OAI_SUBTREE}" "$PROJ" \
    || say "[$t] ⚠️ 报告生成失败（不影响 measures.jsonl）"
  say "[$t] measure 阶段完成，产物在 $OUTD"
}

# ---------- 阶段 4：上传（失败也要尽量传）----------
do_upload() {
  if [ "${SKIP_UPLOAD:-0}" = "1" ]; then say "SKIP_UPLOAD=1，跳过上传"; return 0; fi
  [ -n "${GH_TOKEN:-}" ] || die "缺少 GH_TOKEN（只调试请设 SKIP_UPLOAD=1）"
  [ -n "${GH_REPO:-}" ] || die "缺少 GH_REPO"
  RES="$RES" WORK="$WORK" TARGETS="$TARGETS" OAI_SUBTREE="${OAI_SUBTREE:-}" node -e '
    const fs=require("fs"),os=require("os"),cp=require("child_process");
    const sh=c=>{try{return cp.execSync(c,{stdio:["ignore","pipe","ignore"]}).toString().trim()}catch{return null}};
    const R=process.env.RES, W=process.env.WORK;
    fs.writeFileSync(R+"/meta.json",JSON.stringify({
      targets:(process.env.TARGETS||"").trim().split(/\s+/).filter(Boolean),
      subtree:process.env.OAI_SUBTREE||null,
      generated_at:new Date().toISOString(),
      work_dir:W,
      cpu:{vcpu:os.cpus().length,model:(os.cpus()[0]||{}).model},
      memory_gb:Math.round(os.totalmem()/1e9),
      node:process.version,
      lean:sh("lean --version"),
      commits:{
        mathlib:sh("git -C "+W+"/mathlib4 rev-parse HEAD"),
        oai:sh("git -C "+W+"/oai rev-parse HEAD")
      }
    },null,1));
  ' 2>/dev/null || {
    printf '{"targets":"%s","subtree":"%s","generated_at":"%s","work_dir":"%s"}\n' \
      "$TARGETS" "${OAI_SUBTREE:-}" "$(ts)" "$WORK" > "$RES/meta.json"
  }

  # 压缩要上传的大文件（结果按目标分子目录，见 do_measure）
  find "$RES" -name 'measures.jsonl' -not -name '*.gz' -exec gzip -9 -f {} + 2>/dev/null || true
  # refs.tsv（带权图）是中间产物：大领域约 1.9 GB、全量约 4.8 GB，即使 gzip 也不该进 git。
  # 要它就在 Pod 上手取，或设 LCM_PUSH_REFS=1 强行推（小族才建议）。
  if [ "$LCM_PUSH_REFS" = "1" ]; then
    [ -f "$RES/refs.tsv" ] && gzip -9 -f "$RES/refs.tsv" || true
  else
    say "跳过 refs.tsv（中间产物，避免撑爆仓库）——要它请设 LCM_PUSH_REFS=1"
  fi

  # 体积守卫：GitHub 单文件 100 MiB 会拒绝，>50 MiB 会告警
  # 注意 sizeguard 是递归扫描的，返回的是【相对路径】（如 oai/measures.jsonl.gz）
  say "上传前体积检查:"
  EXCLUDE=""
  if ! node "$APP/sizeguard.mjs" "$RES" $([ "$LCM_PUSH_REFS" = "1" ] && echo --refs); then
    EXCLUDE="measures.jsonl.gz"      # 兜底：超限时排除每个目标下最重的那个
    say "⚠️ 有文件超过单文件上限，已排除 measures.jsonl.gz（summary.json 等仍会推）"
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
  # 用 find 递归遍历（结果在 results/<目标>/ 下），按【文件名】匹配排除项
  while IFS= read -r f; do
    [ -e "$f" ] || continue
    rel="${f#$RES/}"
    base="$(basename "$f")"
    if [ -n "$EXCLUDE" ] && [ "$base" = "$EXCLUDE" ]; then
      say "  排除 $rel（超体积上限，仅留在容器内）"
      continue
    fi
    mkdir -p "$STAGE/results/$(dirname "$rel")"
    cp "$f" "$STAGE/results/$rel" 2>/dev/null || true
  done < <(find "$RES" -type f 2>/dev/null)
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
# 默认 24 小时（多目标 + 低配机器的余量），可用 LCM_DEADLINE_HOURS 调整。设 0 关闭。
DEADLINE_H="${LCM_DEADLINE_HOURS:-24}"
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

# 单目标入口（供分阶段调用）
run_stage() {
  local stage="$1" t="$2"
  case "$stage" in
    toolchain) run_logged toolchain do_toolchain ;;
    deps)      run_logged "deps-$t"      do_deps    "$t" ;;
    build)     run_logged "build-$t"     do_build   "$t" ;;
    measure)   run_logged "measure-$t"   do_measure "$t" ;;
    upload)    run_logged upload         do_upload ;;
  esac
}

case "$PHASE" in
  toolchain) run_logged toolchain do_toolchain ;;
  deps|build|measure)
    # 分阶段：对所有目标跑该阶段（便于中断后接续）
    for t in $TARGETS; do run_stage "$PHASE" "$t"; done
    ;;
  upload) run_logged upload do_upload ;;
  all)
    # 把所有磁盘挂载点拼成一段，直接进飞书 ——
    # 这样"网络卷有没有挂上、工作目录在哪个盘"不必再去翻被刷掉的容器日志
    MOUNTS="$(df -BG 2>/dev/null | awk 'NR>1{printf "%s 总%s 可用%s → %s\n", $1, $2, $4, $6}')"
    notify start "lean-cone-measure 启动" \
      "目标: ${TARGETS}${OAI_SUBTREE:+   (oai 子树=$OAI_SUBTREE)}
主机: ${VCPU} vCPU / ${MEM_GB} GB RAM
并发: JOBS=$JOBS

工作目录: ${WORK}
（来源: ${WORK_SRC:-?}）

挂载点:
${MOUNTS}"

    # 空间不足：先让飞书收到上面那条启动通知（含挂载点），再报失败退出
    if [ "${PREFLIGHT_DISK_FAIL:-0}" = "1" ]; then
      notify fail "lean-cone-measure 未启动：工作盘空间不足" \
        "工作目录: ${WORK}   （来源: ${WORK_SRC:-?}）
可用: ${AVAIL_GB} GB    需要: ${NEED_GB} GB

挂载点:
${MOUNTS}

原因：网络卷(Volume)没挂到这个 Pod 上，工作目录落在系统盘。
办法：① 建 Pod 时挂上 Volume（需同数据中心）
      ② 或把 Container Disk 直接设成 120 GB，不用网络卷
      ③ 或设 LCM_WORK=<卷的实际挂载路径>"
      exit 1
    fi

    # 先做一次占位上传：保证后面全崩时仓库里也有东西
    do_upload >/dev/null 2>&1 || say "首次占位上传失败（不致命，继续）"

    FAILED=0
    run_logged toolchain do_toolchain || FAILED=1
    if [ $FAILED -eq 0 ]; then
      for t in $TARGETS; do
        say "════════ 开始目标: $t ════════"
        if ! run_logged "deps-$t"    do_deps    "$t"; then FAILED=1; break; fi
        do_upload >/dev/null 2>&1 || true          # 阶段留痕
        if ! run_logged "build-$t"   do_build   "$t"; then FAILED=1; break; fi
        do_upload >/dev/null 2>&1 || true
        if ! run_logged "measure-$t" do_measure "$t"; then FAILED=1; break; fi
        do_upload >/dev/null 2>&1 || true
        say "════════ 目标 $t 完成 ════════"
      done
    fi
    do_upload || say "上传阶段也失败了"

    if [ $FAILED -eq 0 ]; then
      # 把本次所有目标的 summary.json 拼进通知
      local_sum=""
      for t in $TARGETS; do
        [ -f "$RES/$t/summary.json" ] && local_sum="$local_sum
[$t] $(node -e "const o=require('$RES/$t/summary.json');console.log('斜率 '+o.fit.slope_bits_per_level+' bit/层, r='+o.fit.r+', 声明 '+o.declarations)" 2>/dev/null)"
      done
      notify ok "lean-cone-measure 全部完成" \
        "目标: ${TARGETS}
总耗时: $(fmt_dur "$(elapsed)")$local_sum
结果: https://github.com/${GH_REPO}/tree/${RESULT_BRANCH}
pod 即将自动关机"
    else
      notify fail "lean-cone-measure 未完成" \
        "目标: ${TARGETS}
已用: $(fmt_dur "$(elapsed)")
日志: https://github.com/${GH_REPO}/tree/${RESULT_BRANCH}/logs
pod 即将自动关机（失败也关，不空转计费）"
    fi

    # 收工关机：无论成功失败都关，避免空转
    [ -n "${WATCHDOG_PID:-}" ] && kill "$WATCHDOG_PID" 2>/dev/null || true
    selfterm
    exit $FAILED
    ;;
  *) die "未知阶段: $PHASE（可用: toolchain|deps|build|measure|upload|all）" ;;
esac
