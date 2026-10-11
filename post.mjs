// 后处理 measure.lean 的输出（TSV: 源 \t 目标 \t 权重），按论文 §3.2 计算三个量。
//
//   primitive（以 § 开头的目标）= 无定义体的常量：unwrapped = 1，depth = 0
//   unwrapped(u) = Σ_i w_i · unwrapped(v_i)       ← 在对数域累加，避免溢出
//   depth(u)     = 依赖 DAG 上到 primitive 的最长路径
//   SCC 用 Tarjan 折叠成一个顶点；SCC 内部引用贡献 0
//
// wrapped length 论文用 token 数（来自 Lean parser）。这里的 TSV 不含源码，
// 所以 wrapped 由 measure.lean 侧另行提供（本次运行不产出，字段留空）。
//
// 用法: node post.mjs <refs.tsv> <输出目录>

import fs from 'node:fs';
import path from 'node:path';

const TSV = process.argv[2];
const OUT = process.argv[3] || '.';
if (!TSV || !fs.existsSync(TSV)) {
  console.error('用法: node post.mjs <refs.tsv> <输出目录>');
  process.exit(1);
}
fs.mkdirSync(OUT, { recursive: true });

const t0 = Date.now();
const log = (...a) => console.log(`[${((Date.now() - t0) / 1000).toFixed(0)}s]`, ...a);
const heapMB = () => (process.memoryUsage().heapUsed / 1e6).toFixed(0);

// ---------- 流式读 TSV ----------
log('读取 TSV…');
const idOf = new Map();
const names = [];
const eu = [], ev = [], ew = [];
let primRefs = 0;

function idOfName(n) {
  let id = idOf.get(n);
  if (id === undefined) { id = names.length; idOf.set(n, id); names.push(n); }
  return id;
}

{
  const fd = fs.openSync(TSV, 'r');
  const CH = 1 << 24;
  const buf = Buffer.allocUnsafe(CH);
  let tail = '';
  let total = 0;
  for (;;) {
    const got = fs.readSync(fd, buf, 0, CH, null);
    if (got <= 0) break;
    const chunk = tail + buf.toString('utf8', 0, got);
    const lines = chunk.split('\n');
    tail = lines.pop();
    for (const line of lines) {
      if (!line) continue;
      const a = line.indexOf('\t');
      if (a < 0) continue;
      const b = line.indexOf('\t', a + 1);
      if (b < 0) continue;
      const src = line.slice(0, a);
      const tgt = line.slice(a + 1, b);
      const w = +line.slice(b + 1);
      if (!(w > 0)) continue;
      const u = idOfName(src);
      let v;
      if (tgt.charCodeAt(0) === 0xA7 /* § */) { v = -1; primRefs++; }
      else v = idOfName(tgt);
      eu.push(u); ev.push(v); ew.push(w);
      total++;
      if (total % 5000000 === 0) log(`  ${(total / 1e6).toFixed(0)}M 边, 名字 ${names.length}, 堆 ${heapMB()} MB`);
    }
    if (process.memoryUsage().heapUsed > 6e9) { log('!! 堆超 6 GB，提前停止读入'); break; }
  }
  fs.closeSync(fd);
}
const M = eu.length, N = names.length;
log(`读入 ${M.toLocaleString()} 条带权边, ${N.toLocaleString()} 个声明, 堆 ${heapMB()} MB`);

// ---------- CSR ----------
log('建 CSR…');
const order = new Int32Array(M);
for (let i = 0; i < M; i++) order[i] = i;
order.sort((a, b) => eu[a] - eu[b]);
const nbr = new Int32Array(M), wts = new Int32Array(M);
const rowStart = new Int32Array(N + 1);
{
  let p = 0;
  for (let i = 0; i < M; i++) {
    const e = order[i];
    nbr[i] = ev[e]; wts[i] = ew[e];
    while (p <= eu[e]) rowStart[p++] = i;
  }
  while (p <= N) rowStart[p++] = M;
}
eu.length = 0; ev.length = 0; ew.length = 0;
log(`  CSR 完成, 堆 ${heapMB()} MB`);

// ---------- Tarjan（迭代式，避免爆栈）----------
log('Tarjan 求 SCC…');
const comp = new Int32Array(N).fill(-1);
const low = new Int32Array(N), disc = new Int32Array(N).fill(-1);
const onStk = new Uint8Array(N);
const stk = new Int32Array(N);
let sp = 0, timer = 0, sccCount = 0;
{
  const callV = new Int32Array(N), callI = new Int32Array(N);
  for (let root = 0; root < N; root++) {
    if (disc[root] !== -1) continue;
    let cs = 0;
    callV[0] = root; callI[0] = rowStart[root];
    disc[root] = low[root] = timer++; stk[sp++] = root; onStk[root] = 1;
    while (cs >= 0) {
      const v = callV[cs];
      let i = callI[cs], recursed = false;
      for (; i < rowStart[v + 1]; i++) {
        const w = nbr[i];
        if (w < 0) continue;
        if (disc[w] === -1) {
          callI[cs] = i + 1; cs++;
          callV[cs] = w; callI[cs] = rowStart[w];
          disc[w] = low[w] = timer++; stk[sp++] = w; onStk[w] = 1;
          recursed = true; break;
        } else if (onStk[w]) { if (disc[w] < low[v]) low[v] = disc[w]; }
      }
      if (recursed) continue;
      if (low[v] === disc[v]) {
        for (;;) { const w = stk[--sp]; onStk[w] = 0; comp[w] = sccCount; if (w === v) break; }
        sccCount++;
      }
      cs--;
      if (cs >= 0) { const pv = callV[cs]; if (low[v] < low[pv]) low[pv] = low[v]; }
    }
    if (root % 200000 === 0 && root > 0) log(`  root ${root}/${N}, SCC ${sccCount}, 堆 ${heapMB()} MB`);
  }
}
log(`  SCC 数 ${sccCount}, 堆 ${heapMB()} MB`);

// ---------- SCC 依赖 + 拓扑序 + 一遍计算 ----------
log('SCC 层拓扑序…');
const sccDep = new Map();   // scc -> Map(目标 scc -> 权重)
const sccPrim = new Map();  // scc -> primitive 引用总权重
for (let u = 0; u < N; u++) {
  const cu = comp[u];
  let dm = sccDep.get(cu);
  if (!dm) { dm = new Map(); sccDep.set(cu, dm); }
  for (let i = rowStart[u]; i < rowStart[u + 1]; i++) {
    const v = nbr[i];
    if (v < 0) { sccPrim.set(cu, (sccPrim.get(cu) || 0) + wts[i]); continue; }
    const cv = comp[v];
    if (cv === cu) continue;
    dm.set(cv, (dm.get(cv) || 0) + wts[i]);
  }
}
const revAdj = new Map();
for (const [cu, dm] of sccDep) for (const cv of dm.keys()) {
  let s = revAdj.get(cv); if (!s) { s = []; revAdj.set(cv, s); }
  s.push(cu);
}
const indeg = new Int32Array(sccCount);
for (const [cu, dm] of sccDep) indeg[cu] = dm.size;
const qq = [];
for (let i = 0; i < sccCount; i++) if (indeg[i] === 0) qq.push(i);
const topo = new Int32Array(sccCount);
let tp = 0;
while (qq.length) {
  const c = qq.pop();
  topo[tp++] = c;
  for (const up of (revAdj.get(c) || [])) if (--indeg[up] === 0) qq.push(up);
}
log(`  拓扑序 ${tp}/${sccCount}${tp < sccCount ? ' ⚠ 有环未覆盖' : ' ✓ 全覆盖'}`);

// log10 域加法：log10(a+b) = max + log10(1 + 10^(-|Δ|))
function log10Add(a, b) {
  if (a === -Infinity) return b;
  if (b === -Infinity) return a;
  const hi = a > b ? a : b, lo = a > b ? b : a, d = lo - hi;
  if (d < -15) return hi;
  return hi + Math.log10(1 + Math.pow(10, d));
}
const sccDepth = new Int32Array(sccCount);
const sccLogU = new Float64Array(sccCount);
for (let t = 0; t < tp; t++) {
  const ci = topo[t];
  let bestD = 0, acc = -Infinity, any = false;
  const dm = sccDep.get(ci);
  if (dm) for (const [cv, c] of dm) {
    any = true;
    if (sccDepth[cv] + 1 > bestD) bestD = sccDepth[cv] + 1;
    acc = log10Add(acc, sccLogU[cv] + Math.log10(c));
  }
  const pw = sccPrim.get(ci);
  if (pw) { any = true; acc = log10Add(acc, Math.log10(pw)); }   // primitive: unwrapped = 1
  if (!any) { bestD = 0; acc = 0; }
  sccDepth[ci] = bestD;
  sccLogU[ci] = acc === -Infinity ? 0 : acc;
}

// 未进入拓扑序的（理论上有环才会有）标 0
for (let i = 0; i < sccCount; i++) if (i >= 0 && !Number.isFinite(sccLogU[i])) { sccDepth[i] = 0; sccLogU[i] = 0; }

// ---------- 落盘 ----------
log('落盘 measures.jsonl…');
const ms = fs.createWriteStream(path.join(OUT, 'measures.jsonl'), { flags: 'w' });
let buf = [];
const depthArr = new Float64Array(N), log2Arr = new Float64Array(N);
for (let u = 0; u < N; u++) {
  const ci = comp[u];
  const d = sccDepth[ci], l2 = sccLogU[ci] * Math.log2(10);
  depthArr[u] = d; log2Arr[u] = l2;
  buf.push(JSON.stringify({ name: names[u], depth: d, log2U: Math.round(l2 * 1000) / 1000 }));
  if (buf.length > 5000) { ms.write(buf.join('\n') + '\n'); buf = []; }
}
if (buf.length) ms.write(buf.join('\n') + '\n');
await new Promise(r => ms.end(r));

// ---------- 汇总 + 回归 ----------
log('回归与汇总…');
const md = a => { const s = Float64Array.from(a).sort(); return s[s.length >> 1]; };
const meanOf = a => a.reduce((x, y) => x + y, 0) / a.length;
const maxOf = a => a.reduce((x, y) => (y > x ? y : x), -Infinity);

let sx = 0, sy = 0, sxx = 0, sxy = 0;
for (let i = 0; i < N; i++) { const x = depthArr[i], y = log2Arr[i]; sx += x; sy += y; sxx += x * x; sxy += x * y; }
const slope = (N * sxy - sx * sy) / (N * sxx - sx * sx);
const intercept = (sy - slope * sx) / N;
let ss = 0, mx = sx / N, my = sy / N, cov = 0, vx = 0, vy = 0;
for (let i = 0; i < N; i++) {
  const r = log2Arr[i] - (slope * depthArr[i] + intercept);
  ss += r * r;
  cov += (depthArr[i] - mx) * (log2Arr[i] - my);
  vx += (depthArr[i] - mx) ** 2; vy += (log2Arr[i] - my) ** 2;
}
const sigma = Math.sqrt(ss / N);
const r = cov / Math.sqrt(vx * vy);

const summary = {
  declarations: N,
  weightedEdges: M,
  primitiveRefs: primRefs,
  scc: sccCount,
  depth: { median: md(depthArr), mean: +meanOf(depthArr).toFixed(3), max: maxOf(depthArr) },
  log2Unwrapped: { median: +md(log2Arr).toFixed(3), mean: +meanOf(log2Arr).toFixed(3), max: +maxOf(log2Arr).toFixed(3) },
  fit: {
    slope_bits_per_level: +slope.toFixed(4),
    intercept: +intercept.toFixed(4),
    residual_sigma: +sigma.toFixed(4),
    three_sigma: +(3 * sigma).toFixed(4),
    r: +r.toFixed(4),
    n: N
  },
  outliers: {
    above_3sigma: (() => { let c = 0; for (let i = 0; i < N; i++) if (log2Arr[i] - (slope * depthArr[i] + intercept) > 3 * sigma) c++; return c; })(),
    below_3sigma: (() => { let c = 0; for (let i = 0; i < N; i++) if (log2Arr[i] - (slope * depthArr[i] + intercept) < -3 * sigma) c++; return c; })()
  },
  paper_reference: {
    slope_reported: '~1 bit per level of depth',
    note: '本实现与论文口径一致：Expr 遍历、primitive=无定义体、depth=最长路'
  }
};
fs.writeFileSync(path.join(OUT, 'summary.json'), JSON.stringify(summary, null, 1), 'utf8');

console.log('\n================ 测量结果 ================');
console.log(JSON.stringify(summary, null, 1));
console.log(`\n结果写入: ${OUT}/summary.json, ${OUT}/measures.jsonl`);
console.log(`用时 ${((Date.now() - t0) / 1000).toFixed(0)}s, 峰值堆 ${heapMB()} MB`);
