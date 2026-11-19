# 简历项目（模板版）：AI 小说创作 Agent 平台

> 按你给的「技术栈 + 中间件与工具 + 编号 Bullet」模板改写，只写项目真实用到的技术，未虚构 Spring Cloud / Redis / RabbitMQ 等组件。
> 可直接粘贴到简历；面试展开材料见 `docs/简历项目-Agent工程与RAG.md`。

**技术栈**：Java 21、Spring Boot 3.4、Spring AI 1.0.9、MyBatis-Plus、MySQL、Elasticsearch 8、SSE、Vue 3 + TypeScript

**中间件与工具**：MySQL 8、Elasticsearch 8（IK 分词 / dense_vector kNN）、Docker、DeepSeek API、Qwen3.7 Embedding

1. 独立负责后端，基于 Spring Boot 3 + Spring AI 将 Agent 能力拆分为「会话 / 运行 / 工具 / 上下文 / 持久化」五层模块：会话与 run 分离、SSE 事件协议（`seq` 自增、多客户端 attach/replay）、MySQL 持久化消息 / run / 任务 / 下载；虚拟线程承载 `ask_user`、长章节生成等阻塞工具，单实例并发 run 上限 8、同一会话单飞，支撑长对话、断线重连与后台任务。

2. 基于 Spring AI `@Tool` 注解建设 Function Calling 工具平台，统一注册 **14 个工具**（数据查询 / RAG / 大纲与章节 / 任务计划 / 用户提问 / 联网搜索 / 文件下载）：自研 OpenAI 兼容流式客户端，按 `tool_calls[].index` 累积工具调用分片、回传 `reasoning_content`、工具异常降级为文本结果、首 token 前对 429/5xx 退避重试、单轮最多 8 次工具循环并在用尽后补一次无工具收尾；工具调用与结果以 `tool_call / tool_result` 事件实时渲染，配合敏感列脱敏、SSRF 防护、分页与下载大小限制约束工具边界。

3. 设计对话中断后的续跑链路：run 生命周期与浏览器连接解耦，事件带 `seq` 写入内存缓冲，断网 / 刷新后通过 `afterSeq` 重放并重新 attach，`/runs/active` 自动接管页面刷新后的未完成运行；断开 **120 秒**仍无人接回才取消，避免用户关页面持续消耗 token。运行 journal 对工具 / 任务 / 提问立即 checkpoint、token 增量按 800ms 节流落 MySQL；进程重启时扫描未完成 run，恢复已产出正文、工具卡片与任务计划并标记 `interrupted`，用户发送「继续」接着做（模型 HTTP 流无法跨进程续传，工具不自动重放，避免重复副作用）。

4. 建设 RAG 语义检索能力：用 Qwen3.7 Embedding（1024 维、8 条/批、最多 4 路并发）生成向量，基于 Elasticsearch `dense_vector` + kNN + tags 过滤完成情节检索；封装 `search_rag / rag_status` 两个 Agent 工具，支持索引自动创建、IK 分词不可用时自动降级，实测「桃园结义 三兄弟」检索 top1 相似度 **0.826**。

5. 设计 1M 窗口长会话压缩：DSH 式阈值触发（`min(W×0.8, W−输出预留−65536)`）+ 保留最近 16% 原文，把早期对话生成结构化检查点并持久化，后续只发送检查点之后的原文；上下文溢出且尚未输出内容时自动压缩并重试一次。

6. 实现 ask_user Human-in-the-loop：支持 3~6 个候选选项 + 用户自定义输入，最长等待 **5 分钟**并保持 SSE 心跳，超时降级、取消唤醒，提问卡与任务计划持久化到会话时间线。

7. 优化 Prompt 前缀缓存：统一「固定内容在前、变化内容在后」（system 稳定、工具定义排序、时间后置），解析 `prompt_cache_hit_tokens` 做会话级/消息级展示；Web Agent 同会话第二轮命中 **93.6%**（2816/3010），联网搜索两阶段复用第一阶段前缀后，第二阶段命中从 **0 → 256/416**。

---

## 说明（不写进简历，面试自用）

- 模板里的 Spring Cloud Alibaba / OpenFeign / Gateway / Nacos / Sentinel / Seata / Sa-Token / Redis / RabbitMQ / Redisson 本项目**没有使用**，所以没有照抄；照抄会在面试追问时露馅。
- 实际架构是**模块化单体**（Spring Boot + 分层 + SSE），不是微服务；简历里按实际写。
- 如果目标岗位强要求微服务经验，建议另起一个真实项目/改造版，把「网关鉴权、服务拆分、Feign 调用、Sentinel 限流、Seata 事务、RabbitMQ 事件」做成可演示的实现后再写。
- 可继续深挖的真实亮点：Function Calling 分片累积与思考模式回传、SSE 事件重放、进程重启状态恢复、RAG 按情节弧窗口 + 重叠 + 续接 + 去重。
