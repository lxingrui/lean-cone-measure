// 把 measure.lean 模板里的占位符替换成实际值。
//
// 为什么不用 sed：模板第 91 行是 Lean 的自定义引号语法
//     #eval go "OUT_PATH_PLACEHOLDER" `Mathlib
// 替换反引号里的 Mathlib 会同时碰到「反引号 + sed 转义 + shell 双引号」三层，
// 实测 `sed: -e expression #1, char 22: unterminated 's' command`。
// 用 node 做纯文本替换没有这些转义问题。
//
// 用法: node subst_template.mjs <模板> <输出> <根模块名> <输出TSV路径>
import fs from 'node:fs';

const [tpl, out, rootModule, tsvPath] = process.argv.slice(2);
if (!tpl || !out || !rootModule || !tsvPath) {
  console.error('用法: node subst_template.mjs <模板> <输出> <根模块名> <TSV路径>');
  process.exit(1);
}

let s = fs.readFileSync(tpl, 'utf8');

// ① 把 OUT_PATH_PLACEHOLDER 换成真实路径（引号内，直接替换即可）
const nPath = s.split('OUT_PATH_PLACEHOLDER').length - 1;
s = s.split('OUT_PATH_PLACEHOLDER').join(tsvPath);

// ② `Mathlib 这个 term（Lean 的自定义引号语法）→ `目标根模块
//    只在反引号紧跟 Mathlib 的位置替换，不碰注释里的普通 Mathlib
const before = s;
s = s.replace(/`Mathlib\b/g, '`' + rootModule);
const nQuote = (before.length !== s.length) ? 1 : 0;

// ③ import Mathlib → import <根模块>（只替换行首的那个 import，不动注释）
const lines = s.split('\n');
let nImport = 0;
for (let i = 0; i < lines.length; i++) {
  if (/^import Mathlib\s*$/.test(lines[i])) {
    lines[i] = 'import ' + rootModule;
    nImport++;
  }
}
s = lines.join('\n');

fs.writeFileSync(out, s, 'utf8');
console.log(`[subst] 路径替换 ${nPath} 处，反引号模块名 ${nQuote} 处，import ${nImport} 处`);
console.log(`[subst] 结果首行: ${s.split('\n').find(l => l.startsWith('import')) || '(无 import 行)'}`);
console.log(`[subst] #eval 行:  ${s.split('\n').filter(l => l.includes('#eval')).join(' | ')}`);
if (nImport === 0) { console.error('[subst] ⚠️ 没有替换到 import 行，检查模板'); process.exit(2); }
