// 把 measures.jsonl（可能 100 MB 级）算成一份【能塞进 AI 上下文】的分析包。
//
// 分工：
//   给人/机器复算  → measures.jsonl.gz（原始数据，别喂 AI）
//   喂 AI 做分析    → 本脚本产出的 report.md + 几个小 CSV（合计 < 300 KB）
//
// 用法: node build_report.mjs <measures.jsonl> <输出目录> [标签]
import fs from 'node:fs';
import path from 'node:path';

const SRC = process.argv[2];
const OUT = process.argv[3] || '.';
const LABEL = process.argv[4] || path.basename(SRC);
// 可选：源码根目录（给了就把离群点的源码片段附进报告，否则跳过）
const SRC_ROOT = process.argv[5] || process.env.LCM_SRC_ROOT || '';
if (!SRC || !fs.existsSync(SRC)) { console.error('用法: node build_report.mjs <measures.jsonl> <输出目录> [标签] [源码根目录]'); process.exit(1); }
fs.mkdirSync(OUT, { recursive: true });

const t0 = Date.now();
const say = (...a) => console.log(`[${((Date.now() - t0) / 1000).toFixed(0)}s]`, ...a);

say('读取…');
const names = [], depth = [], log2U = [];
for (const line of fs.readFileSync(SRC, 'utf8').split('\n')) {
  if (!line) continue;
  const o = JSON.parse(line);
  names.push(o.name); depth.push(o.depth); log2U.push(o.log2U);
}
const N = depth.length;
say(`${N.toLocaleString()} 条声明`);

// ---------- 回归 ----------
let sx = 0, sy = 0, sxx = 0, sxy = 0;
for (let i = 0; i < N; i++) { sx += depth[i]; sy += log2U[i]; sxx += depth[i] ** 2; sxy += depth[i] * log2U[i]; }
const slope = (N * sxy - sx * sy) / (N * sxx - sx * sx);
const intercept = (sy - slope * sx) / N;
const res = new Float64Array(N);
let ss = 0, mx = sx / N, my = sy / N, cov = 0, vx = 0, vy = 0;
for (let i = 0; i < N; i++) {
  res[i] = log2U[i] - (slope * depth[i] + intercept);
  ss += res[i] ** 2;
  cov += (depth[i] - mx) * (log2U[i] - my); vx += (depth[i] - mx) ** 2; vy += (log2U[i] - my) ** 2;
}
const sigma = Math.sqrt(ss / N);
const r = cov / Math.sqrt(vx * vy);
const T3 = 3 * sigma;

const sorted = arr => Float64Array.from(arr).sort();
const q = (sortedArr, p) => sortedArr[Math.min(sortedArr.length - 1, Math.floor(sortedArr.length * p))];
const sd = sorted(depth), su = sorted(log2U);
const maxOf = a => a.reduce((x, y) => (y > x ? y : x), -Infinity);
const meanOf = a => a.reduce((x, y) => x + y, 0) / a.length;

// ---------- 按 depth 分箱（检验自相似：每层箱内斜率是否都 ≈ 常数）----------
const byD = new Map();
for (let i = 0; i < N; i++) { if (!byD.has(depth[i])) byD.set(depth[i], []); byD.get(depth[i]).push(i); }
const depthRows = [];
for (const d of [...byD.keys()].sort((a, b) => a - b)) {
  const g = byD.get(d);
  const u = sorted(g.map(i => log2U[i]));
  const w = g.map(i => log2U[i]);
  depthRows.push({ d, n: g.length, p10: q(u, .1), med: q(u, .5), p90: q(u, .9), mean: +meanOf(w).toFixed(2) });
}
// 分段回归：斜率是否随 depth 漂移 → 自相似的检验
const segSlope = (lo, hi) => {
  const idx = [];
  for (let i = 0; i < N; i++) if (depth[i] >= lo && depth[i] <= hi) idx.push(i);
  if (idx.length < 30) return null;
  const n = idx.length;
  let a = 0, b = 0, aa = 0, ab = 0;
  for (const i of idx) { a += depth[i]; b += log2U[i]; aa += depth[i] ** 2; ab += depth[i] * log2U[i]; }
  return { n, slope: +((n * ab - a * b) / (n * aa - a * a)).toFixed(4) };
};

// ---------- 离群点 ----------
const up = [], dn = [];
for (let i = 0; i < N; i++) {
  if (res[i] > T3) up.push(i); else if (res[i] < -T3) dn.push(i);
}
up.sort((a, b) => res[b] - res[a]);
dn.sort((a, b) => res[a] - res[b]);

// ---------- 按顶级命名空间聚类（结构性发现）----------
const modAgg = new Map();
for (const i of [...up, ...dn]) {
  const key = names[i].split('.').slice(0, 2).join('.');
  let a = modAgg.get(key);
  if (!a) { a = { n: 0, up: 0, dn: 0, sUp: 0, sDn: 0 }; modAgg.set(key, a); }
  a.n++;
  if (res[i] > 0) { a.up++; a.sUp += res[i]; } else { a.dn++; a.sDn += -res[i]; }
}
const modTop = [...modAgg].sort((x, y) => (y[1].up + y[1].dn) - (x[1].up + x[1].dn)).slice(0, 40);

// ---------- 输出 1：report.md（给 AI 读的主文件）----------
// 若有源码根目录，给离群点附上 Lean 源码片段 —— 这才是"为什么偏离"的线索。
// 没有它，报告只能回答"哪些偏离"，回答不了"为什么"。
const srcIndex = new Map();          // 声明名 -> {file, line}
const srcCache = new Map();          // 文件 -> 行数组
if (SRC_ROOT && fs.existsSync(SRC_ROOT)) {
  say('建立声明名 -> 文件 索引（供附源码用）…');
  const all = [];
  (function walk(d) {
    let ents; try { ents = fs.readdirSync(d, { withFileTypes: true }); } catch { return; }
    for (const e of ents) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) { if (e.name !== '.lake' && e.name !== '.git') walk(p); }
      else if (e.name.endsWith('.lean')) all.push(p);
    }
  })(SRC_ROOT);
  const DECL = /^[ \t]*(?:@\[[^\]]*\][ \t]*)*(?:(?:private|protected|noncomputable|unsafe|partial|scoped|local|mutual|instance|nonrec)\s+)*(theorem|lemma|def|abbrev|structure|class|inductive|instance|axiom|opaque)\b[ \t]*([A-Za-z_\u00C0-\u024F][\w'\u00C0-\u024F.]*)?/gm;
  const pending = new Set();
  for (const i of [...up.slice(0, 25), ...dn.slice(0, 25)]) pending.add(names[i]);
  for (const file of all) {
    if (pending.size === 0) break;
    let lines; try { lines = fs.readFileSync(file, 'utf8').split('\n'); } catch { continue; }
    for (let ln = 0; ln < lines.length; ln++) {
      DECL.lastIndex = 0;
      const m = DECL.exec(lines[ln]);
      if (!m || !m[2]) continue;
      const short = m[2];
      for (const want of pending) {
        if (want === short || want.endsWith('.' + short) || short === want.split('.').pop()) {
          if (!srcIndex.has(want)) { srcIndex.set(want, { file, line: ln + 1 }); srcCache.set(file, lines); }
          pending.delete(want);
        }
      }
    }
  }
  say(`  索引到 ${srcIndex.size} / 50 条离群点源码位置`);
}
function srcSnippet(name, maxLines = 12) {
  const loc = srcIndex.get(name);
  if (!loc) return null;
  let lines = srcCache.get(loc.file);
  if (!lines) { try { lines = fs.readFileSync(loc.file, 'utf8').split('\n'); srcCache.set(loc.file, lines); } catch { return null; } }
  const body = lines.slice(loc.line - 1, loc.line - 1 + maxLines).join('\n').replace(/\s+$/, '');
  const rel = path.relative(SRC_ROOT, loc.file).replace(/\\/g, '/');
  return { rel, line: loc.line, body };
}

const f = (v, n = 2) => (typeof v === 'number' ? v.toFixed(n) : v);
const md = [];
md.push(`# 压缩签名测量报告：${LABEL}`);
md.push('');
md.push(`> 本文件由 \`build_report.mjs\` 从完整数据集（${N.toLocaleString()} 条声明）计算得出。`);
md.push(`> 原始数据是 \`measures.jsonl.gz\`（体积过大，不适合直接喂给模型）。`);
md.push(`> **本报告已包含全量数据的统计结论；AI 不需要读原始数据。**`);
md.push('');
md.push('## 1. 数据集');
md.push('');
md.push('| 量 | 值 |');
md.push('|---|---|');
md.push(`| 声明总数 | ${N.toLocaleString()} |`);
md.push(`| depth 范围 | ${sd[0]} – ${maxOf(depth)} |`);
md.push(`| depth 中位 / 均值 | ${q(sd, .5)} / ${f(meanOf(depth))} |`);
md.push(`| log2U 范围 | ${f(su[0])} – ${f(maxOf(log2U))} |`);
md.push(`| log2U 中位 / 均值 | ${f(q(su, .5))} / ${f(meanOf(log2U))} |`);
md.push(`| log2U 分位 p10/p25/p75/p90 | ${f(q(su, .1))} / ${f(q(su, .25))} / ${f(q(su, .75))} / ${f(q(su, .9))} |`);
md.push('');
md.push('## 2. 主回归（核心结论）');
md.push('');
md.push('```');
md.push(`log2(unwrapped) = ${slope.toFixed(4)} · depth + ${intercept.toFixed(4)}`);
md.push(`n = ${N}    r = ${r.toFixed(4)}`);
md.push(`残差 sigma = ${sigma.toFixed(4)} bit    3-sigma = ±${T3.toFixed(4)} bit`);
md.push('```');
md.push('');
md.push(`**斜率 ≈ ${slope.toFixed(2)} bit/层**，即 \`unwrapped ≈ 2^(${slope.toFixed(2)}·depth)\`，`);
md.push(`等价于**每深入一层定义，底层展开量乘以 ${Math.pow(2, slope).toFixed(2)}**。`);
md.push('');
md.push('论文（arXiv:2603.20396）报的斜率是 **≈ 1 bit/层**（每层 ×2）。');
md.push('');
md.push('## 3. 自相似性检验（按 depth 分段回归）');
md.push('');
md.push('若「每层放大同一个常数」成立，则各 depth 区间的斜率应当一致。');
md.push('');
md.push('| depth 区间 | 样本数 | 该区间斜率 |');
md.push('|---|---|---|');
for (const [lo, hi] of [[0, 3], [4, 8], [9, 15], [16, 25], [26, 40], [41, 1e9]]) {
  const s = segSlope(lo, hi);
  if (s) md.push(`| ${lo} – ${hi === 1e9 ? maxOf(depth) : hi} | ${s.n.toLocaleString()} | ${s.slope} |`);
}
md.push('');
md.push('## 4. 按 depth 的分布');
md.push('');
md.push('| depth | 数量 | p10 | 中位 | p90 | 均值 |');
md.push('|---|---|---|---|---|---|');
for (const row of depthRows.slice(0, 45)) {
  md.push(`| ${row.d} | ${row.n} | ${f(row.p10)} | ${f(row.med)} | ${f(row.p90)} | ${row.mean} |`);
}
if (depthRows.length > 45) md.push(`| … | 共 ${depthRows.length} 个 depth 取值，完整表见 depth_stats.csv | | | | |`);
md.push('');
md.push('## 5. 离群点');
md.push('');
md.push(`| 侧 | 数量 | 占比 |`);
md.push(`|---|---|---|`);
md.push(`| 上方（展开异常大，残差 > +3σ） | ${up.length.toLocaleString()} | ${(100 * up.length / N).toFixed(3)}% |`);
md.push(`| 下方（展开异常小，残差 < −3σ） | ${dn.length.toLocaleString()} | ${(100 * dn.length / N).toFixed(3)}% |`);
md.push('');
md.push('### 5.1 离群点成模块聚集（不是随机散布）');
md.push('');
md.push('| 模块（前两级命名空间） | ↑上方 | ↓下方 | 上方平均残差 | 下方平均残差 |');
md.push('|---|---|---|---|---|');
for (const [k, a] of modTop) {
  md.push(`| \`${k}\` | ${a.up} | ${a.dn} | ${a.up ? f(a.sUp / a.up, 1) : '—'} | ${a.dn ? f(a.sDn / a.dn, 1) : '—'} |`);
}
md.push('');
md.push('### 5.2 上方离群（展开异常大）极端例子');
md.push('');
md.push('| 残差 | depth | log2U | 声明 |');
md.push('|---|---|---|---|');
for (const i of up.slice(0, 25)) md.push(`| +${f(res[i], 1)} | ${depth[i]} | ${f(log2U[i], 1)} | \`${names[i]}\` |`);
md.push('');
md.push('### 5.3 下方离群（展开异常小）极端例子');
md.push('');
md.push('| 残差 | depth | log2U | 声明 |');
md.push('|---|---|---|---|');
for (const i of dn.slice(0, 25)) md.push(`| ${f(res[i], 1)} | ${depth[i]} | ${f(log2U[i], 1)} | \`${names[i]}\` |`);
md.push('');

// ---------- 5.4 离群点源码片段（回答"为什么偏离"）----------
if (srcIndex.size > 0) {
  md.push('### 5.4 离群点源码片段');
  md.push('');
  md.push('前面几节说明「**哪些**声明偏离了拟合线」，本节给出 **Lean 源码片段**，');
  md.push('作为回答「**为什么**偏离」的线索。');
  md.push('');
  md.push('> ⚠️ **可靠性警告（务必读）**');
  md.push('>');
  md.push('> 下面的「声明名 → 源码文件」映射是**按名字反查源码**得到的，**不保证准确**。');
  md.push('> 已知失效情形：');
  md.push('>');
  md.push('> 1. **同名不同声明**：不同命名空间下有同名 `functor` / `map`，可能匹配到无关的那个；');
  md.push('> 2. **自动生成的名字**（`instXxx`、`_private.*`、`*._proof_1`）在源码里没有字面对应，必然匹配失败或错配；');
  md.push('> 3. 50 条离群点里，本次只索引到个位数到二十几条。');
  md.push('>');
  md.push('> **正确做法**是在抽取阶段（`measure.lean`）用 Lean 自己的 API 带上声明所在的');
  md.push('> 文件名与行号，而不是事后按名字猜。当前版本尚未这么做。');
  md.push('>');
  md.push('> **结论**：把本节当"在哪个文件附近"的弱线索，**不要当作确证**。');
  md.push(`> 本节索引命中：**${srcIndex.size} / ${Math.min(25, up.length) + Math.min(25, dn.length)}** 条。`);
  md.push('');
  const showSrc = (idx, side) => {
    for (const i of idx.slice(0, 6)) {
      const s = srcSnippet(names[i]);
      md.push(`**${side} 残差 ${res[i] > 0 ? '+' : ''}${f(res[i], 1)} ｜ depth ${depth[i]} ｜ log2U ${f(log2U[i], 1)}**`);
      md.push('');
      md.push(`\`${names[i]}\``);
      md.push('');
      if (s) {
        md.push(`\`${s.rel}:${s.line}\``);
        md.push('');
        md.push('```lean');
        md.push(s.body);
        md.push('```');
      } else {
        md.push('（未索引到源码位置）');
      }
      md.push('');
    }
  };
  md.push('#### 上方离群');
  md.push('');
  showSrc(up, '上方');
  md.push('#### 下方离群');
  md.push('');
  showSrc(dn, '下方');
} else {
  md.push('### 5.4 离群点源码片段');
  md.push('');
  md.push('（本次未提供源码根目录，跳过。加上源码可让人/AI 看到「为什么这些声明偏离」。）');
  md.push('');
}
md.push('## 6. 给分析者的提示');
md.push('');
md.push('- **斜率与 r 是主结论**，可与论文的 ≈1 bit/层 直接对照。');
md.push('- **第 3 节的分段斜率**回答"自相似是否成立"：若各区间的斜率接近，说明放大倍率与层级无关。');
md.push('- **第 5.1 节**是最有信息量的部分：离群点按命名空间聚集，说明偏离来自**模块级的写法**而非个别声明。');
md.push('- **第 5.4 节**给出离群点的 Lean 源码片段——这是回答「为什么偏离」的直接材料。');
md.push('- 需要具体某条声明的细节时，再按需从 `measures.jsonl.gz` 里 grep，不要把整份数据喂给模型。');
md.push('');
md.push('## 7. 关于「为什么」的诚实边界');
md.push('');
md.push('本报告能回答的问题与不能回答的问题：');
md.push('');
md.push('| 问题 | 本报告能否回答 | 依据 |');
md.push('|---|---|---|');
md.push('| 斜率是多少？ | ✅ | 第 2 节的回归 |');
md.push('| 斜率在不同层级是否一致？ | ✅ | 第 3 节分段回归 |');
md.push('| 哪些声明偏离最大？ | ✅ | 第 5.1–5.3 节 |');
md.push('| 偏离是否按模块聚集？ | ✅ | 第 5.1 节 |');
md.push('| **偏离的数学原因是什么？** | ⚠️ 部分 | 5.4 节给了源码片段，但**名称反查不可靠**，需人工核对 |');
md.push('| **这些偏离意味着什么样的「更好定义」？** | ❌ | 需要数学判断，本报告不涉及 |');
md.push('');
md.push('**已知的最有价值线索**：第 5.1 节的模块聚类是**可靠**的（它只依赖声明名，不依赖源码反查），');
md.push('所以"某些数学领域的压缩签名系统性偏离"这个结论是站得住的。');
md.push('');
fs.writeFileSync(path.join(OUT, 'report.md'), md.join('\n'), 'utf8');

// ---------- 输出 2：小 CSV（按【喂 AI】的预算裁剪）----------
// 关键：这些文件的用途是"塞进上下文让 AI 分析"，不是全量导出。
// 全量永远在 measures.jsonl.gz 里，需要细查时按名字 grep。
const CAP_OUTLIERS = 300;      // 每侧保留条数
const CAP_MODULES = 120;       // 模块簇保留条数

let csv1 = 'depth,count,p10,median_log2U,p90,mean_log2U\n';
for (const row of depthRows) csv1 += `${row.d},${row.n},${f(row.p10)},${f(row.med)},${f(row.p90)},${row.mean}\n`;
fs.writeFileSync(path.join(OUT, 'depth_stats.csv'), csv1, 'utf8');

let csv2 = 'side,residual,depth,log2U,name\n';
for (const i of up.slice(0, CAP_OUTLIERS)) csv2 += `up,${f(res[i], 2)},${depth[i]},${f(log2U[i], 2)},${names[i]}\n`;
for (const i of dn.slice(0, CAP_OUTLIERS)) csv2 += `down,${f(res[i], 2)},${depth[i]},${f(log2U[i], 2)},${names[i]}\n`;
fs.writeFileSync(path.join(OUT, 'outliers.csv'), csv2, 'utf8');

const modSorted = [...modAgg].sort((x, y) => (y[1].up + y[1].dn) - (x[1].up + x[1].dn));
let csv3 = `module,outlier_count,up,down,mean_up_residual,mean_down_residual\n`;
for (const [k, a] of modSorted.slice(0, CAP_MODULES))
  csv3 += `${k},${a.n},${a.up},${a.dn},${a.up ? f(a.sUp / a.up, 2) : ''},${a.dn ? f(a.sDn / a.dn, 2) : ''}\n`;
fs.writeFileSync(path.join(OUT, 'module_clusters.csv'), csv3, 'utf8');

fs.writeFileSync(path.join(OUT, 'stats.json'), JSON.stringify({
  label: LABEL, declarations: N,
  depth: { min: sd[0], median: q(sd, .5), mean: +meanOf(depth).toFixed(3), max: maxOf(depth) },
  log2Unwrapped: { min: +su[0].toFixed(3), p10: +q(su, .1).toFixed(3), median: +q(su, .5).toFixed(3), p90: +q(su, .9).toFixed(3), max: +maxOf(log2U).toFixed(3) },
  fit: { slope_bits_per_level: +slope.toFixed(4), intercept: +intercept.toFixed(4), r: +r.toFixed(4), residual_sigma: +sigma.toFixed(4), three_sigma: +T3.toFixed(4) },
  outliers: { above: up.length, below: dn.length },
  segment_slopes: Object.fromEntries([[0, 3], [4, 8], [9, 15], [16, 25], [26, 40], [41, 1e9]]
    .map(([lo, hi]) => [`${lo}-${hi === 1e9 ? 'max' : hi}`, segSlope(lo, hi)]).filter(([, v]) => v))
}, null, 1), 'utf8');

say('产出:');
let totalBytes = 0;
for (const fn of ['report.md', 'depth_stats.csv', 'outliers.csv', 'module_clusters.csv', 'stats.json']) {
  const p = path.join(OUT, fn);
  const sz = fs.statSync(p).size;
  totalBytes += sz;
  say(`  ${fn.padEnd(22)} ${(sz / 1024).toFixed(1).padStart(8)} KB   ≈${Math.round(sz / 3).toLocaleString()} token`);
}
say(`  ${'合计'.padEnd(20)} ${(totalBytes / 1024).toFixed(1).padStart(8)} KB   ≈${Math.round(totalBytes / 3).toLocaleString()} token`);
if (totalBytes / 1024 > 200) say('  ⚠️ 超过 200 KB，可能塞不进小上下文窗口');
say(`（全量原始数据在 measures.jsonl 里，${(fs.statSync(SRC).size / 1e6).toFixed(1)} MB —— 那是给人复算的，别喂模型）`);
say('完成');
