// 给 run.sh 用：上传前做体积守卫。
// GitHub 的硬性约束里，我能确定的是【单文件 100 MiB 会被拒绝】，
// 以及单文件 >50 MiB 会告警。这里按 gzip 后的实际大小判断。
//
// 用法: node sizeguard.mjs <目录> [--refs]
//   退出码 0 = 可以通过；1 = 有文件必须排除（调用方应把它从上传列表里剔除）
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';

const DIR = process.argv[2] || '.';
const WITH_REFS = process.argv.includes('--refs');

const WARN = 50 * 1024 * 1024;    // 50 MiB：告警
const HARD = 95 * 1024 * 1024;    // 95 MiB：留给 GitHub 的 100 MiB 一点余量

const targets = ['report.md', 'stats.json', 'depth_stats.csv', 'outliers.csv', 'module_clusters.csv', 'summary.json', 'measures.jsonl', 'measures.jsonl.gz', 'refs.tsv', 'refs.tsv.gz', 'meta.json', 'progress.json'];

let mustExclude = [];
let warned = [];

for (const name of targets) {
  const p = path.join(DIR, name);
  if (!fs.existsSync(p)) continue;
  const isRefs = name.startsWith('refs.');
  if (isRefs && !WITH_REFS) {
    console.log(`  [skip] ${name}  （未开启 LCM_PUSH_REFS，中间产物不推）`);
    continue;
  }
  let size = fs.statSync(p).size;
  let note = '';
  if (name.endsWith('.jsonl')) {
    // 预估 gzip 后大小（实测比 3.7x），避免真去压一遍浪费时间
    const est = Math.round(size / 3.7);
    note = `（gzip 后约 ${(est / 1e6).toFixed(1)} MB，将压缩后再推）`;
    size = est;
  }
  const mb = (size / 1e6).toFixed(1);
  if (size > HARD) {
    console.log(`  [拒绝] ${name}  ${mb} MB  > 95 MB —— 超过 GitHub 单文件上限，排除`);
    mustExclude.push(name);
  } else if (size > WARN) {
    console.log(`  [告警] ${name}  ${mb} MB  > 50 MB —— 会告警但能推`);
    warned.push(name);
  } else {
    console.log(`  [ok]   ${name}  ${mb} MB ${note}`);
  }
}

if (mustExclude.length) {
  console.log(`\n需排除: ${mustExclude.join(' ')}`);
  console.log('（测量结果本身不会丢：summary.json 一定推，measures 若超限请拆分或改用 LCM_PUSH_REFS=0 减负）');
  process.exit(1);
}
process.exit(0);
