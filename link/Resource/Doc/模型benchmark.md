# 模型 benchmark

在最终的测试过程中，发现选择的模型翻译的准确度不高，特别是 中 -> 英 -> 日  
于是挑选了不同类型的模型来进行 benchmark 测试

本次实验基于 Link-Model/benchmark 提供的离线翻译 benchmark pipeline 完成，目标是在不改动现有 Link app 运行时的前提下，对候选离线翻译模型进行统一的工程化评估。评测覆盖 zh-en 与 zh-ja 两个方向，重点比较翻译质量、推理延迟、内存占用以及量化后模型体积，为后续模型选型提供依据。本次报告所分析的结果对应 Link-Model/benchmark/results/translation/20260408T113621Z/ 这一轮运行产物。

## 测试结果

本轮 benchmark 对 `m2m100-418m`、`marian-direct` 和 `marian-pivot` 三套 `seq2seq` 翻译系统在 `zh-en` 与 `zh-ja` 两个方向上进行了对比评测。由于本次运行未安装 COMET 依赖，质量比较主要基于 `chrF++`、`BLEU` 和 `mustPreserve` 指标进行。整体结果如下表所示。

| Route | Model         | Quality Rank | Efficiency Rank | p50 Latency (ms) | Peak RSS (MB) | INT8 Size (bytes) | Eliminated | Elimination Reason                                |
| ----- | ------------- | ------------ | --------------- | ---------------: | ------------: | ----------------: | ---------- | ------------------------------------------------- |
| zh-en | marian-direct | 1            | 2               |            83.26 |        901.42 |         238549357 | Yes        | must_preserve_rate < 0.85                         |
| zh-en | marian-pivot  | 2            | 1               |            82.26 |        713.02 |         238549357 | Yes        | must_preserve_rate < 0.85                         |
| zh-en | m2m100-418m   | 3            | 3               |           300.70 |       2329.05 |        1206789818 | Yes        | must_preserve_rate < 0.85                         |
| zh-ja | m2m100-418m   | 1            | 3               |           321.24 |       2259.50 |        1206789818 | Yes        | must_preserve_rate < 0.85                         |
| zh-ja | marian-pivot  | 2            | 2               |           197.00 |        938.42 |         428919314 | Yes        | must_preserve_rate < 0.85                         |
| zh-ja | marian-direct | 3            | 1               |           110.72 |       1230.53 |         435966729 | Yes        | empty_output_count > 0; must_preserve_rate < 0.85 |

从结果来看，`zh-en` 方向上 Marian 系列在质量和效率上均优于 `m2m100-418m`，其中 `marian-pivot` 具有最佳推理效率，`marian-direct` 的质量排序最高。`zh-ja` 方向上，`m2m100-418m` 的质量相对最好，但延迟和内存开销最大；`marian-direct` 虽然速度最快，但出现空输出，稳定性最差。最终所有模型均因未通过 `mustPreserve` 门槛而被淘汰，因此本轮没有产生推荐模型。

## 对比的模型

本轮 benchmark 共对比了 3 套 seq2seq 翻译系统。

- marian-direct 表示单模型直接翻译方案，其中 zh-en 使用 Helsinki-NLP/opus-mt-zh-en，zh-ja 使用 Helsinki-NLP/opus-mt-tc-big-zh-ja；
- marian-pivot 表示通过英语中间语进行两跳翻译，其中 zh-en 使用 Helsinki-NLP/opus-mt-zh-en，zh-ja 使用 Helsinki-NLP/opus-mt-zh-en + Helsinki-NLP/opus-mt-en-jap；
- m2m100-418m 则使用单一多语模型 facebook/m2m100_418M 同时支持 zh-en 与 zh-ja 两个方向的直译。三者分别代表了单模型直译、pivot 两跳翻译以及多语统一模型三种典型离线路线。

## 评测步骤

整个 benchmark 流程分为 prepare、run 和 report 三个阶段。

- 在 prepare 阶段，系统首先下载原始模型与 tokenizer，随后完成 ONNX 导出、INT8 量化以及 artifact manifest 生成；
- 在 run 阶段，所有模型统一在 CPU 上进行推理测试，固定采用 batch_size=1、do_sample=false、num_beams=1、greedy decode、max_new_tokens=256 的解码参数，每个系统和每个方向先 warmup 2 次，再对 15 条测试语料执行 5 轮正式测量；
- 在 report 阶段，对预测结果和运行统计进行汇总，输出 predictions.jsonl、runtime-summary.json、metrics.json、leaderboard.csv 和 report.md。
- 测试语料直接复用现有 translation_performance_corpus.json，共 15 条样本，按 short、medium、long 三类均匀分布，主要用于工程 smoke benchmark。

评测过程中同时记录质量和性能指标

- 运行指标包括 cold_start_ms、sentence_latency_ms、p50_ms、p95_ms、total_duration_s、tokens_per_second、peak_rss_mb、empty_output_count 和 error_count；质量指标包括 COMET、chrF++、BLEU 以及 mustPreserve 命中率。
- 本次运行由于未安装 COMET 依赖，因此最终质量比较主要依赖 chrF++、BLEU 与 mustPreserve。
- 决策上，benchmark 不输出单一混合总分，而是分别给出质量榜、效率榜和 Pareto frontier，并设置自动淘汰规则：若模型出现错误输出、空输出、mustPreserve_rate < 0.85，或 COMET 明显低于 Marian 基线，则不进入推荐集合。

## 结果分析

从 zh-en 方向来看，Marian 系列表现明显优于 m2m100-418m。marian-direct 与 marian-pivot 的 chrF++ 和 BLEU 均高于 m2m100-418m，同时在推理延迟、峰值内存和量化后模型体积上也具有明显优势。其中 marian-pivot 的 p50 latency 最低，marian-direct 在质量排序中位列第一，说明 Marian 路线在 zh-en 场景下更具工程落地潜力。不过，三者都未通过 mustPreserve_rate >= 0.85 的淘汰阈值，因此本轮没有任何 zh-en 系统被自动推荐。这说明当前 zh-en 路线虽然已经具备可用 baseline，但在关键短语保真和局部语义稳定性上仍存在不足。

zh-ja 方向的表现则整体不理想。marian-direct 虽然延迟最低，但出现了空输出与异常重复文本，质量指标几乎失效；marian-pivot 的 zh->en 中间结果基本正常，但 en->ja 第二跳结果明显退化，导致最终输出不可用；m2m100-418m 在三者中质量相对最好，至少能够生成基本可读的日语文本，但仍未通过 mustPreserve 门槛，且推理成本最高。因此，当前模型池下 zh-ja 方向尚不存在可上线方案，需要进一步更换候选模型或重新设计技术路线。

## 结婚

总体来看，本轮 benchmark 更适合作为工程选型与风险排查依据，而不是最终质量定版。结论上，zh-en 方向可以保留 Marian 作为后续优化基线，其中 marian-direct 和 marian-pivot 都具备继续打磨的价值；zh-ja 方向则不建议沿用本轮候选模型直接推进，需要优先解决模型适配性、关键语义保真和输出稳定性问题后，再进入下一轮评测。
