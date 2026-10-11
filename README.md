# mathlib / OAI-Lean 压缩签名测量器（云端一次性运行）

把 Aksenov–Bodnia–Freedman–Mulligan（[arXiv:2603.20396](https://arxiv.org/abs/2603.20396)）
§3 的三个量（`depth` / `wrapped length` / `unwrapped length`）在 mathlib4 与 OpenAI 数学仓库上跑一遍，
把结果推回本仓库的 `results` 分支，**不推送任何密钥**。

## 设计前提：仓库只有约 33 KB 纯文本

**所有重物都在 pod 上现拉**（RunPod 出网不计费）：

| 内容 | 在哪来 |
|---|---|
| Lean 工具链 v4.34.1（~3 GB） | pod 上 `elan-init.sh` 现装 |
| mathlib4 + 41 个依赖（~1.5 GB） | pod 上 `git clone` / `lake update` |
| mathlib 预编译缓存（~5 GB） | pod 上 `lake exe cache get` |
| OpenAI 数学仓库（~1.5 GB） | pod 上 `git clone` |
| 本仓库（**33 KB**） | 你本地推一次，手机流量也够 |

**不需要自建 Docker 镜像** —— RunPod 直接选官方 `ubuntu:24.04`。

## 怎么用

开一台 **8 vCPU / 64 GB / 80 GB 容器盘** 的 RunPod **CPU Pod**，镜像选 `ubuntu:24.04`，
Docker command 填一行把本仓库拉下来执行，注入 `GH_TOKEN` + `GH_REPO`，设 **Max Runtime**。

完整步骤、规格依据、防翻车说明见 [RUNBOOK.md](RUNBOOK.md)。

## 测量口径（照抄论文 §3.1–3.2）

- 顶点 = Lean 环境里所有声明；边 = 声明间 `.const` 引用，**带权重**（引用次数）
- 遍历 **elaboration 之后**的 `Expr`（不是源码），因此 `simp` / `rw` 展开出的内部引用可见
- **primitive** = 没有定义体的常量（`induct` / `ctor` / `rec` / `axiom`）；其 `unwrapped = 1`、`depth = 0`
  - 注意：`Nat.add` **有**定义体（展开到 `Nat.rec`）⇒ 可展开；`Nat.rec` 是 recursor ⇒ primitive
- `unwrapped(u) = Σ_i w_i · unwrapped(v_i)`，在对数域累加避免溢出
- `depth(u)` = 依赖 DAG 上到 primitive 的**最长**路径
- SCC 用 Tarjan 折叠，内部引用贡献 0

## 环境变量

| 变量 | 必填 | 说明 |
|---|---|---|
| `GH_TOKEN` | 上传时需要 | GitHub **Fine-grained** PAT，只授权本仓库 `Contents: Read and write` |
| `GH_REPO` | 是 | 形如 `yourname/your-repo` |
| `TARGET` | 否 | `mathlib`（默认）或 `oai`；决定测量哪个库 |
| `OAI_SUBTREE` | `oai` 时建议 | 只编译这个子树，例如 `OAI/Analysis/Fourier`。留空 = 全量（**不推荐**，见 RUNBOOK） |
| `OAI_JOBS` | 否 | 传给 `lake -j` 的并发数，默认按 vCPU 自动 |
| `SKIP_UPLOAD` | 否 | 设 `1` 只测量不上传（调试用） |

## 分阶段运行（推荐）

编译很贵，脚本因此分成**可接续的阶段**，每阶段产物落盘，中断后重跑不会白费：

```bash
./run.sh setup      # 装 elan + 拉依赖 + mathlib 缓存
./run.sh build      # 编译目标
./run.sh measure    # 跑 Lean 元程序抽引用 + 算三个量
./run.sh upload     # 推结果
./run.sh all        # 全流程（默认）
```

## 输出

```
results/
  summary.json          # 三个量的汇总统计 + 回归斜率
  measures.jsonl        # 每条声明的 depth / log2U / wrapped
  refs.tsv.gz           # 带权依赖图（可能很大，可关）
  meta.json             # 库版本、commit、运行环境、耗时
```

## 许可与来源

- 本仓库代码：你自己的选择
- 测量的目标库在运行时由脚本克隆，**不随本仓库分发**：
  - `mathlib4` — Apache-2.0
  - OpenAI 数学仓库 — Apache-2.0（`openai/NavierStokesAndEuler` 同类）
