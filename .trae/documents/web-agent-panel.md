# 网页端右侧 Agent 面板（Spring AI 实现）

## 1. 背景与目标

网页控制台（`web/app`）目前只能按固定页面操作：想查数据要去「数据浏览」，想生成大纲要去「写作」，想找素材要去「情节素材库」。

本次新增一个**常驻在右侧的聊天 Agent**，用自然语言驱动这些后端能力：

- 查看当前设备的数据（概览、任意表、单条详情）
- 检索 RAG 情节素材并借鉴
- 一键生成大纲、单章正文（**只生成，不落库**）
- 读取已有大纲 / 章节

交互上对齐 DeepSeek harness：**每次工具调用都能看到「调用参数 → 执行中 → 返回内容」**，并且可以**真正中断**——不是只断开前端，而是同时停掉 LLM 流、正在执行的工具和长任务生成。

## 2. 范围

### 做

| 项 | 说明 |
|---|---|
| 后端 Agent 服务 | Spring AI `ChatClient` + `@Tool` 工具调用 |
| SSE 事件流 | 文本增量 + 工具调用/结果 + 阶段进度 |
| 真中断 | 前端 abort + 取消接口 + Flux 取消 + 工具内检查 |
| 右侧面板 | 可折叠、可拖宽、消息与工具卡片 |
| 设备隔离 | 复用 `x-device-id`，工具按当前设备读写 |

### 不做

- Agent 删除/覆盖用户已有数据（生成类只新增作品与章节，不改旧作品）
- 驱动界面跳转（`ui_action`）
- 修改 APK 版本号 / 发 release

## 3. 架构

```
AgentPanel.vue (右侧)
   │ POST /api/agent/chat        SSE（fetch + AbortSignal）
   │ POST /api/agent/runs/{id}/cancel
   ▼
AgentController
   ▼
AgentService  ──► ChatClient(prompt).tools(AgentTools).toolContext(runId)
   │                    │
   │                    └─ @Tool 方法执行时通过 ToolContext 拿到 AgentRun，写出 trace 事件
   ├─ AgentRunRegistry  运行中的 run（runId → AgentRun）
   └─ AgentRun          取消标志 + SSE 输出流 + 心跳
```

复用现有实现：

| 能力 | 复用 |
|---|---|
| 数据查询 | `DatabaseManager.app()` + `Db.query()` + `SchemaCatalog` |
| RAG | `RagService.search()` / `status()` |
| 一键大纲 | `OutlineGenerationService.generate(body, Sink)` |
| 单章正文 | `ChapterGenerationService.generate(body, Sink)` |
| SSE 写法 | `NovelWritingController` 的 `startSse / writeEvent` 同款格式 |
| 前端流式 | `api/client.ts` 的 `postStream` |
| Markdown | `components/RichText.vue` |

## 4. SSE 事件协议

每行 `data: {json}`，空行分隔。

| type | 字段 | 说明 |
|---|---|---|
| `start` | `runId` | 开始，前端记录 runId |
| `delta` | `text` | 助手正文增量 |
| `tool_call` | `id` `name` `args` `startedAt` | 工具开始，前端插入卡片 |
| `tool_result` | `id` `name` `ok` `summary` `data` `elapsedMs` | 工具成功 |
| `tool_error` | `id` `name` `error` `elapsedMs` | 工具失败 |
| `stage` | `label` `index` `total` | 长任务分阶段进度 |
| `context` | `tokens` `window` `threshold` `percent` `compacted` | 请求发送前的上下文占用（估算或上次实测） |
| `usage` | `promptTokens` `completionTokens` `totalTokens` `cachedTokens` `window` `threshold` `percent` | 每轮请求的真实 token 用量（API usage） |
| `compaction` | `count` `kept` `freedTokens` `summaryChars` `estimatedTokens` | 历史被压缩成检查点 |
| `done` | `elapsedMs` | 正常结束 |
| `cancelled` | — | 被中断 |
| `error` | `error` | 失败 |

心跳：每 15 秒写一行 `: ping`，避免长工具执行期间被代理/浏览器判超时。

### 上下文占用与自动压缩

窗口 W 默认 1,000,000（DeepSeek Flash / Pro 均为 1M），可在面板设置里按模型覆盖。

- 触发阈值 `floor(min(W × 0.8, W − 输出预留 − 65,536))`；
- 压缩时把最旧的一段历史摘要成 `<compacted-summary>` 检查点，最近 `(W − 输出预留) × 16%` 的对话保留原文；
- 摘要写进 `agent_sessions.summary`，`summary_upto` 记录覆盖到的消息 id，后续轮次只加载它之后的消息；
- 压力优先用上一轮 API 返回的 `prompt_tokens`，没有时按中文 1 字 ≈ 1 token 估算；
- 提供方返回上下文溢出且还没输出内容时，压缩后重试一次；
- `POST /api/agent/sessions/{id}/compact` 手动压缩（对应 DSH 的 `/compact`），会话正在生成时返回 409。

面板展示：输入框上方显示「上下文占用百分比 + 缓存命中率」，悬浮可看本轮输入/输出/缓存命中 token 与压缩阈值；
`GET /api/agent/sessions/{id}` 的 `context` 字段带 `tokens / cachedTokens / cachePercent / window / threshold / percent`，
刷新或切换会话后缓存命中率仍能显示（落库在 `agent_sessions.context_tokens / context_cached_tokens` 与
`agent_messages.prompt_tokens / completion_tokens / cached_tokens`）。

## 5. 工具清单

| 工具名 | 入参 | 返回要点 |
|---|---|---|
| `get_overview` | — | 各库各表行数、设备号 |
| `list_data` | `db` `table` `page` `pageSize` `keyword` | 列名 + 分页行（长文本截断 300 字） |
| `get_row` | `db` `table` `id` | 单行完整字段 |
| `search_rag` | `query` `size` `tags` | hits：标题/情节/原文摘录/标签/情感/相似度 |
| `rag_status` | — | 索引状态、书目、标签 |
| `generate_outline` | `genre` `theme` `protagonist` `worldview` `majorCount` `minorCount` `extra` | **保存为作品**（outline_records + outline_chapters），返回 outlineId/章节数，过程中推送 `stage` |
| `list_outlines` | `limit` | 已有作品列表（id/题材/摘录） |
| `list_chapters` | `outlineId` | 作品章节清单（eventIndex/标题/是否已写） |
| `generate_chapter` | `outlineId` `eventIndex` `minWords` `extra` | **正文写入对应章节**（outline_chapters.content，status=completed），返回 chapterId |

约束：

- 行数上限 50，单字段文本上限 300 字，工具返回整体上限约 8KB
- 表名/库名必须通过 `SchemaCatalog.hasTable()` 校验
- 除 `generate_outline` / `generate_chapter` 外全部只读；写库必须走 `SyncStore.writeRow`（否则手机端同步不到）
- 生成成功但落库失败时，工具仍返回内容并带 `saved:false` / `saveError`，不会让整次生成白做

## 6. 真正的中断

| 层 | 机制 |
|---|---|
| 前端 | `AbortController.abort()` + `POST /runs/{id}/cancel`（`keepalive: true`） |
| LLM 流 | `flux.takeWhile(t -> !run.cancelled())` + `doOnCancel(run::cancel)`，取消会 propagete 到上游 HTTP |
| 工具 | 每个 `@Tool` 入口 `run.checkCancelled()`，抛 `AgentCancelledException` 立即中止 |
| 长任务 | `OutlineGenerationService` 的 `Sink` 回调里检查取消并抛异常；**无需改动原有生成服务** |
| 断连 | SSE `write` 抛 `IOException` 时标记 cancelled，避免"前端停了后端还在烧 token" |

## 7. 文件清单

### 后端目录结构（已按功能重组）

```
src/main/java/com/deepseekapp/webserver/
├─ WebServerApplication.java
├─ ai/                      NovelAiService、AiSettings（共享 AI 客户端）
├─ config/                  AppProperties、ServerInfo、StartupBanner
├─ db/                      Db、DatabaseManager、SchemaCatalog（共享存储层）
├─ util/                    Json、NetworkUtil
├─ web/                     Api、ApiException、过滤器、全局异常、首页
├─ usb/                     USB 反向隧道
├─ sync/                    SyncController、SyncStore（设备同步）
└─ feature/
   ├─ agent/
   │   ├─ api/AgentController.java
   │   ├─ service/          AgentService、AgentRun、AgentRunRegistry、AgentEvent、AgentCancelledException
   │   └─ tool/             DataTools、RagTools、WritingTools、AgentToolSupport、AgentToolCatalog
   ├─ data/                 DataController、MetaController、TransferController、Importer、Exporter
   ├─ writing/              WritingController、NovelWritingController、OutlineStageController
   │                        与大纲/章节/战斗相关服务
   ├─ rag/                  RagController、RagService
   ├─ bili/                 BiliController 与 B 站转写服务
   └─ update/               AppUpdateController、AppUpdateService
```

### Agent 模块职责划分

| 类 | 职责 |
|---|---|
| `AgentController` | SSE 入口、取消接口、工具清单 |
| `AgentService` | ChatClient 编排、取消传播、心跳 |
| `AgentRun` / `AgentRunRegistry` | 运行实例与取消标志 |
| `AgentToolSupport` | 调用追踪、返回截断、参数校验、通用小工具 |
| `DataTools` | 数据概览、查表、单条详情 |
| `RagTools` | 语义检索、素材库状态 |
| `WritingTools` | 生成大纲、列出大纲、生成章节 |
| `AgentToolCatalog` | 聚合三个工具类，供模型注册与面板展示 |

### 前端（新增/修改）

```
src/api/agent.ts
src/stores/agent.ts
src/components/agent/AgentPanel.vue
src/components/agent/AgentToolCard.vue
src/api/client.ts        （增加 onEvent / postKeepalive）
src/layouts/AppLayout.vue（插入面板 + 顶栏开关）
```

## 8. 验证

1. 后端 `mvnw spring-boot:run`，前端 `pnpm dev`
2. 「现在库里有什么数据」→ 出现 `get_overview` / `list_data` 卡片，参数与返回可展开
3. 「找几个雨夜重逢的素材」→ `search_rag` 卡片（当前库 0 条，返回空是正确结果）
4. 「按仙侠生成一个大纲」→ `stage` 进度推进 + 最终 JSON；**确认 outline 表行数不变**
5. 生成中途点「停止」→ 前端立即停；后端无新 token；表行数不变
6. 只改网页端，执行一次 `pnpm run build`

## 9. 风险

- Spring AI 1.0.9 流式 + 工具回环依赖 DeepSeek 的 OpenAI 兼容实现。若不稳定，退化为「先 `call()` 决策工具，再 `stream()` 输出最终答案」，工具过程仍然可见。
- `ToolContext` 若不透传，工具仍可执行但无 trace 事件；实现里对 `null` 做兜底。
