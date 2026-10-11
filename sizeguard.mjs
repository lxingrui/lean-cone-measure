// 给 run.sh 用：上传前做体积守卫。
// GitHub 的硬性约束里，我能确定的是【单文件 100 MiB 会被拒绝】，
// 以及单文件 >50 MiB 会告警。这里按 gzip 后的【预估】大小判断。
//
// 结果按目标分目录（results/mathlib/、results/oai/），所以递归扫描。
//
// 用法: node sizeguard.mjs <目录> [--refs]
//   退出码 0 = 可以通过；1 = 有文件超过单文件上限，调用方应把它排除
import fs from 'node:fs';
import path from 'node:path';

const DIR = process.argv[2] || '.';
const WITH_REFS = process.argv.includes('--refs');

const WARN = 50 * 1024 * 1024;    // 50 MiB：告警
const HARD = 95 * 1024 * 1024;    // 95 MiB：留给 GitHub 的 100 MiB 一点余量
const GZIP_RATIO = 3.73;          // 实测（measures.jsonl 样本 229,725 行）

function walk(dir, acc = []) {
  let ents;
  try { ents = fs.readdirSync(dir, { withFileTypes: true }); } catch { return acc; }
  for (const e of ents) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, acc);
    else if (e.isFile()) acc.push(p);
  }
  return acc;
}

const mustExclude = [];
const warned = [];
let skipped = 0;

for (const p of walk(DIR).sort()) {
  const rel = path.relative(DIR, p).replace(/\\/g, '/');
  const name = path.basename(p);

  // 中间产物（带权图），默认不推
  if (name.startsWith('refs.') && !WITH_REFS) { skipped++; continue; }

  let size = fs.statSync(p).size;
  let note = '';
  if (name.endsWith('.jsonl')) {
    const est = Math.round(size / GZIP_RATIO);
    note = `（gzip 后约 ${(est / 1e6).toFixed(1)} MB）`;
    size = est;
  }
  const mb = (size / 1e6).toFixed(1);
  if (size > HARD) {
    console.log(`  [拒绝] ${rel}  ${mb} MB  > 95 MB —— 超过 GitHub 单文件上限，排除`);
    mustExclude.push(rel);
  } else if (size > WARN) {
    console.log(`  [告警] ${rel}  ${mb} MB  > 50 MB —— 会告警但能推`);
    warned.push(rel);
  } else {
    console.log(`  [ok]   ${rel}  ${mb} MB ${note}`);
  }
}
if (skipped) console.log(`  [skip] ${skipped} 个 refs.* 中间产物（未开启 LCM_PUSH_REFS）`);

if (mustExclude.length) {
  console.log(`\n需排除 ${mustExclude.length} 个文件（超 GitHub 单文件上限）：`);
  for (const f of mustExclude) console.log(`  - ${f}`);
  console.log('（summary.json / report.md 等小文件仍会推，测量结论不会丢）');
  process.exit(1);
}
process.exit(0);
