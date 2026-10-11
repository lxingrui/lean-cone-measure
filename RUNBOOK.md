# RUNBOOK — RunPod CPU 部署与运行

## 0. 一句话

开一台 **8 vCPU / 64 GB / 80 GB 容器盘** 的 RunPod **CPU Pod**，镜像用**官方 `ubuntu:24.04`**，
Docker command 填一行 `bash -c "..."`（把仓库拉下来执行），设 **`Max Runtime`**，
注入 `GH_TOKEN` + `GH_REPO`。剩下的 pod 自己干。

**仓库里只有约 33 KB 纯文本。** Lean 工具链、mathlib、42 个依赖全部在 **pod 上现拉** ——
RunPod 出网不计费，所以**不占你本地任何流量**。

---

## 1. 规格怎么定的（都有实测依据）

本机参考：`mathlib4` 编译完成后 **96 MB 源码 → 6.2 GB 编译产物**（约 65×），
`.lake/build/lib` 里 111,995 个 `.olean`；压缩签名计算阶段峰值堆 **1.67 GB**。

| 项 | 推荐 | 下限 | 依据 |
|---|---|---|---|
| vCPU | **8** | 4 | `lake -j` 并行；超过 8 收益递减（依赖链有串行瓶颈） |
| 内存 | **64 GB** | 32 GB | 单文件编译峰值 2–6 GB；OAI 有 100+ 个 5 MB 巨文件，单进程可达 8–12 GB |
| 容器盘 | **80 GB** | 60 GB | 见下面拆解 |
| 网络卷 | **不需要** | — | 一次性任务 |
| 时钟 | 5 GHz 目标 | — | Lean 编译单线程重，主频直接换算成墙钟时间 |

### 磁盘拆解（单族）

| 内容 | 大小 |
|---|---|
| Lean 工具链（运行时装） | ~3 GB |
| 目标库源码（OAI） | 1.5 GB |
| mathlib 源码 + 其余 41 个依赖 | ~1.5 GB |
| mathlib 编译产物 | ~6.2 GB |
| **单族** OAI 编译产物 | 5–15 GB |
| 中间数据 `refs.tsv` | 2–4 GB |
| 系统 + 余量 | ~10 GB |
| **合计** | **~30 GB** → 80 GB 很宽裕 |

> ⚠️ **不要全量编译 OAI。** 1.5 GB 源码按 65× 外推约 **100 GB** olean，
> 而且作者在 `lean/README.md` 里明确写了：
> *"Compiling the entire library may fail if Linux's `vm.max_map_count` is too low"*，
> 并建议 *"compiling only small portions at a time"*。
> `run.sh` 在你 `TARGET=oai` 却没给 `OAI_SUBTREE` 时**会警告，磁盘 <120 GB 直接拒绝**。

### 时间与成本

| 阶段 | 时间 |
|---|---|
| toolchain（pod 上下 Lean） | 5–10 分钟 |
| deps（克隆 + `lake update` + 打 24 个补丁） | 20–60 分钟 |
| mathlib 缓存拉取 | 15–40 分钟（失败则退回自行编译 1–3 小时） |
| 编译单族 | 30 分钟 – 2 小时 |
| measure | 5–30 分钟 |

8 vCPU / 64 GB 大致 **$0.4–0.8 / 小时**（以控制台为准），单族总耗时 2–4 小时 ⇒ **约 $1–3**。

---

## 2. ⚠️ 防翻车：Pod 不能自杀

**销毁 Pod 需要 RunPod API key，而我们不把任何密钥放进 pod。**
所以**必须**用平台侧的 **Max Runtime**：

- 网页：创建 Pod → **Advanced → Max Runtime**
- CLI：`runpodctl create pod ... --max-runtime 6h`

这是**平台强制**的，pod 内脚本崩了也生效 —— 比在脚本里写自杀逻辑可靠得多。

**两个后果要接受：**

1. **容器盘随 Pod 销毁一起消失。** Max Runtime 要按预估 **×1.5** 留足，
   否则会出现"编译完了、还没上传就被销毁"。
2. `run.sh all` 会在**开工前先做一次占位上传**（空壳 + `meta.json`），
   并且 `upload` 阶段**失败也执行**。所以最坏情况下仓库里也有一份日志。

> 如果确实想要"跑完立刻销毁"，就得给 pod 一个 RunPod API key——
> 但那与"不推送密钥"冲突。**`Max Runtime` 是更安全的折中。**

---

## 3. 密钥怎么放（唯一要守的纪律）

**绝不**把 token 写进任何会被提交的文件。本仓库已经：

- `.gitignore` 排除 `.env` / `secrets*` / `results/` / `logs/`
- 脚本只从**环境变量**读 `GH_TOKEN`

**正确做法：**

1. GitHub → Settings → Developer settings → **Fine-grained tokens** → 新建
2. **Repository access**：只选这一个仓库
3. **Permissions**：`Contents: Read and write`（其余全不给）
4. 过期时间：**1 天**
5. 在 RunPod 创建 Pod 时加到 **Environment Variables**：`GH_TOKEN`、`GH_REPO`

> PAT 单仓库 + 1 天有效期 ⇒ 即使泄漏损失也有限。跑完建议直接删掉这个 token。

---

## 4. 部署步骤（不需要建镜像）

### 4.1 先把仓库推上去

```bash
cd lean-cone-measure
git init && git add . && git commit -m "init"
git remote add origin https://github.com/<你>/<仓库>.git
git push -u origin main
```

**待传体积约 33 KB** —— 手机流量也够。

### 4.2 在 RunPod 建 CPU Pod

| 字段 | 值 |
|---|---|
| Pod type | **CPU**（不要 GPU） |
| vCPU | 8 |
| RAM | 64 GB |
| Container disk | 80 GB |
| Image | **`ubuntu:24.04`**（官方镜像，无需自建） |
| Docker command | 见下 |
| Environment | `GH_TOKEN`、`GH_REPO`、`TARGET`、`OAI_SUBTREE` |
| **Max Runtime** | **6h** |
| Volume | 不需要 |

**Docker command**（一行，把仓库拉下来执行）：

```bash
bash -c "apt-get update -qq && apt-get install -y -qq git ca-certificates >/dev/null && git clone --depth 1 https://github.com/<你>/<仓库>.git /app && bash /app/run.sh all"
```

> 若仓库是 private，把 clone URL 换成带 token 的形式：
> `https://x-access-token:$GH_TOKEN@github.com/<你>/<仓库>.git`
> （token 从环境变量取，不落盘到镜像里）

**环境变量示例**：

```
GH_TOKEN      = ghp_...（Fine-grained，1 天）
GH_REPO       = <你>/<仓库>
TARGET        = oai
OAI_SUBTREE   = OAI/Analysis/Fourier
JOBS          = 6
```

### 4.3 先干跑一次（强烈建议）

第一次把 `SKIP_UPLOAD=1` 加上、`TARGET=mathlib`、`Max Runtime` 设 3h，
只验证 toolchain + deps 两个阶段能不能过。**这两步过了，后面基本就稳了。**

---

## 5. 分阶段运行

编译很贵，脚本因此分阶段，产物落盘，中断后重跑会跳过已完成阶段：

```bash
bash /app/run.sh toolchain   # 装 Lean（约 3 GB，pod 侧流量）
bash /app/run.sh deps        # 克隆 + lake update + 打补丁
bash /app/run.sh build       # 编译
bash /app/run.sh measure     # 抽出引用 + 算三个量
bash /app/run.sh upload      # 推结果
bash /app/run.sh all         # 全流程（默认）
```

---

## 6. 选哪个 OAI 子树

`formalization.yaml`（79 KB）是现成的族目录。选族建议：

| | 理由 |
|---|---|
| ✅ `OAI/Analysis/*` 里数学内容重的族 | 有真实数学结构，`depth` 分布有代表性 |
| ✅ `OAI/NumberTheory/*` | 同上 |
| ❌ `OAI/Combinatorics/Ramsey/CycleClique/Construction/Certificates*` | 20 个文件各 5 MB / 1.8 万条声明，是**纯证书链**；编译最慢且对压缩签名分析无代表性 |

**先用小族验证方法可行，再决定要不要放大。**

---

## 7. 结果怎么拿回来

结果推到 **`results` 分支**（不污染 `main`），因为 `refs.tsv.gz` 可能很大：

```bash
git fetch origin results && git checkout results
```

`summary.json` 里是可直接与论文对照的数：

```json
{
  "declarations": 12345,
  "weightedEdges": 987654,
  "depth":         { "median": 12, "mean": 18.5, "max": 123 },
  "log2Unwrapped": { "median": 18.8, "max": 148.8 },
  "fit": { "slope_bits_per_level": 1.12, "r": 0.968, "residual_sigma": 4.43, "three_sigma": 13.3 },
  "outliers": { "above_3sigma": 6852, "below_3sigma": 4386 }
}
```

**对照论文**：他们报 `log2(unwrapped)` 随 `depth` 线性、斜率 ≈ 1 bit/层。

---

## 8. 已知偏差（分析时必须记住）

1. **版本**：OpenAI 钉的 mathlib 是 `d13f23b`（约 2025-10）。
   方案在**同一套 pinned 环境**里测量，所以 OAI 与 mathlib 的点**在同一坐标系**、可比。
2. **`depth` 口径敏感**：本机实测 mathlib 最大 depth 只有 94，而论文隐含接近 345。原因未查明。
   ⇒ **"哪些点算离群"依赖 depth 口径**。
3. `meta.json` 会记录实际 commit 与运行环境，便于事后核对。

---

## 9. 故障排查

| 症状 | 处理 |
|---|---|
| `lean` 装完仍不在 PATH | `run.sh` 里已 `export PATH="$ELAN_HOME/bin:$PATH"`；若你手改了，注意 elan 默认装到 `/root/.elan` |
| `lake update` 报补丁失败 | 仓库自带 24 个 `patches/*-lean4341.patch`，`lakefile.lean` 会自动打。看 `logs/deps.log` |
| 编译 OOM 被杀 | 降并发：`-e JOBS=4` |
| 磁盘写满 | `TARGET=oai` 必须给 `OAI_SUBTREE`；脚本会在 <120 GB 时拒绝全量 |
| 上传 403 | PAT 权限不对：要 `Contents: Read and write`，且 repository access 含本仓库 |
| 被 Max Runtime 杀掉 | 预估不足。缩小 `OAI_SUBTREE` 或提高上限重跑（注意容器盘不保留中间产物） |
| `refs.tsv` 为空 | 看 `logs/measure.log`；常见原因是根模块名不对（`import` 那行被 sed 改错） |
