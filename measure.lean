/-
按 Aksenov/Bodnia/Freedman/Mulligan (arXiv 2603.20396v1) §3.1 的精确方法，
遍历 Lean 环境里每个声明的【elaboration 之后】的 Expr，统计 .const 引用次数。

为什么必须走 Expr 而不是解析源码：
  `simp` / `rw` 等 tactic 在 elaboration 时会展开成大量内部引用；
  源码里一次 tactic 调用只是一个 token，源码解析会严重低估展开量。
  （论文 §3.2 明确以这一点解释了为什么 wrapped 用 token 数而非引用数。）

输出 TSV: <源声明名>\t<目标名>\t<权重>
  · 目标名以 § 开头 = primitive（没有定义体的常量：induct / ctor / rec / axiom）
  · 关键区分：`Nat.add` 有定义体（展开到 `Nat.rec`）⇒ 可展开；
              `Nat.rec` 是 recursor，无定义体 ⇒ primitive

run.sh 会替换下面两个占位：
  · import Mathlib        → import <根模块>
  · OUT_PATH_PLACEHOLDER  → 实际输出路径
-/
import Mathlib

open Lean

/-- 论文 §3.1 的 collectElems，语义照抄 -/
partial def collectElems (e : Expr) (acc : Std.HashMap Name Nat) : Std.HashMap Name Nat :=
  match e with
  | .const declName _             => acc.insert declName (acc.getD declName 0 + 1)
  | .app fn arg                   => collectElems arg (collectElems fn acc)
  | .lam _ binderType body _      => collectElems body (collectElems binderType acc)
  | .forallE _ binderType body _  => collectElems body (collectElems binderType acc)
  | .letE _ type value body _     => collectElems body (collectElems value (collectElems type acc))
  | .mdata _ expr                 => collectElems expr acc
  | .proj _ _ struct              => collectElems struct acc
  | .sort _                       => acc.insert (Name.mkSimple "Sort") (acc.getD (Name.mkSimple "Sort") 0 + 1)
  | _                             => acc

unsafe def go (outPath : String) (rootModule : Name) : IO Unit := do
  enableInitializersExecution
  let t0 ← IO.monoMsNow
  let env ← Lean.importModules (#[rootModule] : Array Import) {} (loadExts := true)
  let t1 ← IO.monoMsNow
  IO.eprintln s!"环境加载: {t1 - t0} ms"

  -- 【关键】可展开 = 有定义体。仅此判据，不按名字前缀/模块归属判断。
  -- 这样 Init/Std/Batteries 里的 def 也会被继续展开（Nat.add → Nat.rec），
  -- 而不是像早期版本那样在底层被整片截断。
  let expandable : Std.HashSet Name :=
    env.constants.fold (init := {}) (fun s n ci =>
      match ci with
      | .defnInfo _ | .thmInfo _ => s.insert n
      | _ => s)

  let h ← IO.FS.Handle.mk outPath IO.FS.Mode.write
  let mut buf := ""
  let mut nDecl := 0
  let mut nSrc := 0
  let mut nEdge := 0
  let mut nExpandableTarget := 0
  let mut nPrimitiveTarget := 0

  for (cname, info) in env.constants.toList do
    nDecl := nDecl + 1
    let hasBody := info.value?.isSome
    -- 源集合：有定义体的声明（定理/定义）才是图的节点
    if !hasBody then continue
    nSrc := nSrc + 1

    let mut acc : Std.HashMap Name Nat := {}
    acc := collectElems info.type acc
    match info.value? with
    | some v => acc := collectElems v acc
    | none   => pure ()

    for (tname, w) in acc.toList do
      if tname == cname then continue
      let ok := expandable.contains tname
      if ok then nExpandableTarget := nExpandableTarget + 1 else nPrimitiveTarget := nPrimitiveTarget + 1
      let label := if ok then toString tname else "§" ++ toString tname
      buf := buf ++ s!"{cname}\t{label}\t{w}\n"
      nEdge := nEdge + 1
      if buf.length > 400000 then
        h.putStr buf; buf := ""
    if nSrc % 50000 == 0 then
      IO.eprintln s!"  源声明 {nSrc}, 边 {nEdge}"
  h.putStr buf
  h.flush
  IO.eprintln s!"完成: 环境常量 {nDecl}, 有定义体的声明 {nSrc}"
  IO.eprintln s!"      可展开目标引用 {nExpandableTarget}, primitive 目标引用 {nPrimitiveTarget}"
  IO.eprintln s!"      带权边总数 {nEdge}"
  IO.eprintln s!"输出: {outPath}"

#eval go "OUT_PATH_PLACEHOLDER" `Mathlib
