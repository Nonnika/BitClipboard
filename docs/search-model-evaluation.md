# 语义搜索模型诊断（2026-10-14）

用户报告：搜索“代码”找不全代码，搜索 `code` 返回 IP。此前添加的逐词代码识别规则已撤回。

## 复现方法

[`search_cases.json`](../Tests/SemanticRuntimeTests/search_cases.json) 包含 18 条公开合成片段和 13 个查询，覆盖编程片段、IP、色值、网址、会议、天气、数据库错误、晚餐、电话号码、日语以及无匹配查询。不读取用户的剪贴板。

类别查询的预期集合在文件中明确列出。本次将 Python、JavaScript、Swift、SQL、shell、HTML、CSS、JSON 配置视为“代码相关内容”；这是一组测试定义，并不代表所有用户对代码类别的解释。P@k 中 k 为预期集合大小，“代码”和 `code` 的 k=8。

```bash
TASK_PYTHON="$HOME/Library/Application Support/BitClipboard/SemanticSearch/venv/bin/python3"
PYTHONDONTWRITEBYTECODE=1 "$TASK_PYTHON" scripts/evaluate-search.py \
  --model current --output .build/search-current.json --require-perfect-recall
PYTHONDONTWRITEBYTECODE=1 "$TASK_PYTHON" scripts/evaluate-search.py \
  --model google-full --output .build/search-google-full.json
```

评测强制离线。`--require-perfect-recall` 会在有预期片段落到 top-k 之外时返回非零状态，当前模型确实无法通过；它不是常规单元测试的一部分。无匹配查询输出完整分数供检查，P@k 不适用于空预期集合。

替代模型先使用 `hf download` 下载脚本中固定的 revision，再传入 `--cache-dir`，例如 Qwen 两款模型缓存在 `.build/qwen-model-cache`，E5 缓存在 `.build/comparison-model-cache`。

## 本机对照结果

所有模型均采用官方检索提示与池化方式、CPU float32。下表比较的是未施加搜索结果阈值的排序，不能当作产品总体准确率，也不能跨模型直接比较分数。

| 模型 / 向量 | “代码” P@8 | `code` P@8 | 结论 |
| --- | ---: | ---: | --- |
| 当前 EmbeddingGemma 2 / 256 | 3/8 | 5/8 | 色值、电话号码、IPv6 排到代码前面 |
| EmbeddingGemma 2 / 768 | 3/8 | 5/8 | 完整维度仍有同样混淆 |
| Qwen3-Embedding-0.6B / 1024 | 4/8 | 4/8 | 网站、色值、IPv6 混入结果 |
| multilingual-e5-small / 384 | 3/8 | 6/8 | 中文类别查询和无匹配查询仍不可靠 |
| Qwen3-Reranker-0.6B | 7/8 | 5/8 | 仍漏召回，默认网页相关性任务不等于类别判断 |

当前 worker 的向量与官方 `encode_query` / `encode_document` 输出截取到 256 维、重新归一化后的结果一致（绝对误差小于 1e-5）。官方完整向量对“代码”的相似度：Python 片段 0.6978、IPv4 0.7062、色值 0.7619。因此当前问题并非只由向量截断或 Swift 排序引起。

对 Google 模型也比较了无提示、相似度、分类提示；对 Qwen 模型比较了用于所有查询的统一剪贴板任务指令，均未稳定解决本组类别检索问题。没有据此替换生产模型或新增关键词规则。

## 实现的局限

1. 嵌入余弦相似度是语义接近程度，不是“该内容属于指定类别”的置信度。现有测试仅覆盖几个具体描述，不能证明类别查询有效。
2. 当前 0.72 下限及距最高分 0.06 的窗口会额外删去得分较低的相关片段；提高阈值只能减少展示量，不能修复错误排序。
3. 若要可靠支持“找全某类内容”，需要验证具备类别理解能力的模型或通用分类阶段，并用独立留出样例测量召回率、误匹配及延迟；不能从本组样例推导通用阈值。

官方模型说明：[EmbeddingGemma 2](https://huggingface.co/google/embeddinggemma-2)、[Qwen3 Embedding](https://huggingface.co/Qwen/Qwen3-Embedding-0.6B)、[Qwen3 Reranker](https://huggingface.co/Qwen/Qwen3-Reranker-0.6B)、[multilingual-e5-small](https://huggingface.co/intfloat/multilingual-e5-small)。
