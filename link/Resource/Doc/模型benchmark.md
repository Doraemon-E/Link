# 模型 benchmark

在最终的测试过程中，发现选择的模型翻译的准确度不高，特别是 中 -> 英 -> 日  
于是挑选了不同类型的模型来进行 benchmark 测试

本次实验基于 Link-Model/benchmark 提供的离线翻译 benchmark pipeline 完成，目标是在不改动现有 Link app 运行时的前提下，对候选离线翻译模型进行统一的工程化评估。评测覆盖 zh-en 与 zh-ja 两个方向，重点比较翻译质量、推理延迟、内存占用以及量化后模型体积，为后续模型选型提供依据。本页统一汇总了 4 个候选模型的测试结果，数据来自同一套 benchmark pipeline、相同测试语料和相同解码参数下的运行产物：`20260408T113621Z` 与 `20260408T134251Z`。

## 测试结果

本次 benchmark 统一对 `m2m100-418m`、`marian-direct`、`marian-pivot` 和 `granite-3-1-2b-instruct` 4 个候选模型在 `zh-en` 与 `zh-ja` 两个方向上进行了对比评测。由于运行环境未安装 COMET 依赖，质量比较主要基于 `chrF++`、`BLEU` 和 `mustPreserve` 指标进行。整体结果如下表所示。

| Route | Model                   | Lane    | Quality Rank | Efficiency Rank | p50 Latency (ms) | Peak RSS (MB) | INT8 Size (bytes) | chrF++ | BLEU  | mustPreserve | Eliminated | Elimination Reason                                |
| ----- | ----------------------- | ------- | ------------ | --------------- | ---------------: | ------------: | ----------------: | -----: | ----: | -----------: | ---------- | ------------------------------------------------- |
| zh-en | marian-direct           | seq2seq | 1            | 2               |            83.26 |        901.42 |         238549357 |  46.72 | 21.35 |        0.443 | Yes        | must_preserve_rate < 0.85                         |
| zh-en | marian-pivot            | seq2seq | 2            | 1               |            82.26 |        713.02 |         238549357 |  46.72 | 21.35 |        0.443 | Yes        | must_preserve_rate < 0.85                         |
| zh-en | m2m100-418m             | seq2seq | 3            | 3               |           300.70 |       2329.05 |        1206789818 |  43.63 | 15.98 |        0.307 | Yes        | must_preserve_rate < 0.85                         |
| zh-en | granite-3-1-2b-instruct | llm     | 4            | 4               |          2220.97 |       2900.00 |        2642260109 |  39.11 | 10.56 |        0.125 | Yes        | must_preserve_rate < 0.85                         |
| zh-ja | m2m100-418m             | seq2seq | 1            | 3               |           321.24 |       2259.50 |        1206789818 |  19.75 |  0.00 |        0.258 | Yes        | must_preserve_rate < 0.85                         |
| zh-ja | granite-3-1-2b-instruct | llm     | 2            | 4               |          4034.27 |       2942.44 |        2642260109 |  13.22 |  0.00 |        0.191 | Yes        | must_preserve_rate < 0.85                         |
| zh-ja | marian-pivot            | seq2seq | 3            | 2               |           197.00 |        938.42 |         428919314 |   5.87 |  0.00 |        0.000 | Yes        | must_preserve_rate < 0.85                         |
| zh-ja | marian-direct           | seq2seq | 4            | 1               |           110.72 |       1230.53 |         435966729 |   1.02 |  0.00 |        0.000 | Yes        | empty_output_count > 0; must_preserve_rate < 0.85 |

从结果来看，`zh-en` 方向上 Marian 系列仍然最强，`marian-pivot` 具有最佳推理效率，`marian-direct` 的质量排序最高；`m2m100-418m` 位于中间，`granite-3-1-2b-instruct` 则在质量和效率两侧都明显落后。`zh-ja` 方向上，`m2m100-418m` 的质量相对最好，`granite-3-1-2b-instruct` 虽然质量略高于两条 Marian 路线，但延迟、内存和模型体积都显著更高；`marian-direct` 虽然速度最快，但因为出现空输出，稳定性最差。最终 4 个模型全部因为未通过 `mustPreserve` 门槛而被淘汰，因此本轮没有产生推荐模型。

## 对比的模型

本页共对比 4 个翻译模型，其中包含 3 条 `seq2seq` 路线与 1 条 `llm` 路线。

- marian-direct 表示单模型直接翻译方案，其中 zh-en 使用 Helsinki-NLP/opus-mt-zh-en，zh-ja 使用 Helsinki-NLP/opus-mt-tc-big-zh-ja；
- marian-pivot 表示通过英语中间语进行两跳翻译，其中 zh-en 使用 Helsinki-NLP/opus-mt-zh-en，zh-ja 使用 Helsinki-NLP/opus-mt-zh-en + Helsinki-NLP/opus-mt-en-jap；
- m2m100-418m 则使用单一多语模型 facebook/m2m100_418M 同时支持 zh-en 与 zh-ja 两个方向的直译；
- granite-3-1-2b-instruct 使用 ibm-granite/granite-3.1-2b-instruct，通过 `causal_llm` executor 以指令跟随方式直接生成目标语言结果。几者分别代表了单模型直译、pivot 两跳翻译、多语统一模型以及指令式 LLM 翻译四种不同路线。

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

从 zh-en 方向来看，Marian 系列表现最稳。`marian-direct` 与 `marian-pivot` 的 `chrF++`、`BLEU` 和 `mustPreserve` 都明显高于 `m2m100-418m` 与 `granite-3-1-2b-instruct`，同时在延迟、峰值内存和量化后模型体积上也具有明显优势。其中 `marian-pivot` 的 `p50 latency` 最低，`marian-direct` 在质量排序中位列第一，说明 Marian 路线在 zh-en 场景下依然最有工程落地潜力。相比之下，`granite-3-1-2b-instruct` 虽然可以稳定输出文本，但质量与效率都没有优势，暂时不适合作为 zh-en 的主要候选。

zh-ja 方向的表现则整体不理想。`m2m100-418m` 在 4 个模型里质量相对最好，`granite-3-1-2b-instruct` 排在第二，但两者的推理成本都偏高；`marian-pivot` 的两跳路径在第二跳出现明显退化，`marian-direct` 虽然延迟最低，但出现了空输出与异常重复文本，稳定性最差。`granite-3-1-2b-instruct` 在 zh-ja 上说明小型 instruct LLM 确实比当前 Marian 路线更有机会生成可读结果，但代价是更高的 CPU 延迟、更高的内存占用，以及更大的量化体积。综合来看，当前 4 个模型都未跨过 `mustPreserve_rate >= 0.85` 的门槛，zh-ja 方向仍然没有可直接上线的离线方案。

## 总结

总体来看，本轮 benchmark 更适合作为工程选型与风险排查依据，而不是最终质量定版。结论上，zh-en 方向可以保留 Marian 作为后续优化基线，其中 marian-direct 和 marian-pivot 都具备继续打磨的价值；zh-ja 方向则不建议沿用本轮候选模型直接推进，需要优先解决模型适配性、关键语义保真和输出稳定性问题后，再进入下一轮评测。
