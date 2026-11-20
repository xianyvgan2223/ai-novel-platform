# 变更请求：网页端数据浏览与 Agent 恢复能力升级

| 项目 | 内容 |
|------|------|
| CR 编号 | CR-2026-11-20-001 |
| 状态 | 待评审 |
| 提交日期 | 2026-11-20 |
| 变更类型 | 功能新增 / 体验优化 / 缺陷修复 |
| 影响端 | Web Console（`web/app` + `web/server-java`） |
| 版本影响 | 不修改 App 版本号、不构建 APK、不更新 `latest.json` |
| 数据库影响 | 服务端 MySQL 新增 7 张表，启动时自动创建；App 侧 DB 不变 |

## 一、变更概述

本变更集中提升网页端对手机数据的可用性，并补齐写作功能与 Agent 的中断恢复能力，主要包括：

1. 数据浏览改为「先选择要显示的内容，再在当前页下方展开」；
2. 新增只读「查看大纲 / 查看正文」，大纲支持按大事件筛选；
3. 网页端新增「小说灵感」完整功能；
4. B 站转文字新增提取记录，新增下载页；
5. 补齐所有 AI 写作功能的设置入口，写作工具 / 小事件润色真正使用设置；
6. Agent 中断后恢复工具卡状态、已产出输出，并提供「继续任务」；
7. 切换设备自动刷新、情节素材库按作品查看。

**范围外：** App 5.5.7 发版相关改动（`pubspec.yaml`、App 版本文件、APK、`latest.json`）以及移动端聊天 Markdown / 搜索体验改动不属于本 CR。

## 二、背景与问题

- 数据浏览此前直接打开原始表：英文列名、大量 JSON 与内部字段、长 ID 换行，用户很难找到并读懂手机同步上来的数据；
- 查看大纲只能看到列表接口截断后的概要，缺少完整正文阅读入口；
- 移动端「小说灵感」在网页端缺失；
- B 站转文字完成后文字稿无法回看，下载工具缺少统一入口；
- 部分写作 AI 页面没有设置入口，写作工具与小事件润色不读取设置；
- Agent 在浏览器断线 / 服务端重启后，历史中可能出现永远「执行中」的工具卡，重启后只能手动输入「继续」。

## 三、变更内容

### 1. 数据浏览（`/browse`）

- 顶部只保留「选择要显示的内容」：可搜索下拉框按库 / 模块分组，展示中文表名、模块与行数；
- 6 个「常用内容」快捷入口；
- 选中后记录在当前页下方展开，不跳页；顶部选择器始终保留，可跨库（deepseek ↔ novel）切换；
- 列头显示中文名 + 原始字段名；
- JSON / 内部 / 敏感字段默认收起（`skeleton`、`characters`、`foreshadows`、`selected_events`、`reasoning_content`、`apiKey` 等），可勾选「显示全部字段」；
- 布尔值显示「是 / 否」，时间格式化，JSON 显示标签并可在详情中格式化查看；
- 详情抽屉增加标题 / ID / 时间 / 状态摘要；编辑表单使用中文标签；
- 修正长 ID 换行；
- 旧地址 `/browse/:db/:table` 仍兼容并自动展开。

### 2. 查看大纲 / 查看正文

- 左侧「创作」新增独立入口，选作品页支持 `intent=view|read`；
- 新增 `/writing/outline/:id/view` 与 `/writing/outline/:id/read`；
- 阅读页按 id 获取完整正文，绕过列表接口约 300 字截断；
- 大纲查看新增「按大事件显示」：勾选大事件后只显示所选大事件及其小事件，默认全选，支持全选 / 清空，刷新保留选择。

### 3. 小说灵感（网页版）

- 新增 `/writing/inspiration`：会话列表、推演 / 聊天切换、时间线、设定 / 人物卡 / 大纲导入 / 设置；
- 推演按设置并行生成多个候选（默认 3 个），支持采用、编辑、删除、重新推演、代际切换、多候选 AI 合并；
- 聊天模式与推演同一条时间线；
- 支持从已有大纲导入大 / 小事件作为本会话范围（不改大纲）；
- 服务端新增 `inspiration_*` 6 张表与 `POST /api/writing/novel/inspiration/stream`。

### 4. B 站提取记录与下载页

- 完整提取结束后保存文字稿到 `<data-dir>/bili/transcripts/`，最多 200 条，原子写入；
- 新增 `GET/DELETE /api/bili/transcripts` 接口，`done` 事件返回 `transcriptId`；
- B 站页新增「提取记录」：查看、下载 txt、删除；
- 新增 `/downloads` 页：展示 Agent 下载工具说明与下载库文件，可保存 / 删除。

### 5. 写作 AI 设置

- 覆盖：一键生成大纲、大纲编辑、匹配大纲格式、小事件详写、小事件写作、AI 写战斗、写作工具、小说灵感；
- 新增 `writing_tools_settings` 表与「写作工具 AI 设置」抽屉；
- `WritingService.optimize / drawCards` 读取模型、temperature、max_tokens、thinking、补充提示词；
- 小事件润色 / 继续改写补传 `chapterRequestSettings()`。

### 6. Agent 中断恢复

- 浏览器 / SSE 断线且服务端仍在运行：自动 `attachRun(runId, lastSeq)` 重放，工具与输出继续；
- 服务端重启：`AgentRunRecoveryRunner` 扫描 `running` 运行，补 `interrupted` 消息；恢复前把 `running` 工具改为 `error`、`waiting` 提问改为 `timeout`；
- 前端历史加载同样收尾未完成工具，避免永久「执行中」；
- 中断消息新增「继续任务」：先尝试接管活动运行，否则带已完成工具摘要与未完成工具列表发送继续提示；
- 不自动重放有副作用的工具。

### 7. 其他

- 切换设备后 `<router-view>` 按 `deviceEpoch` 重建，页面数据同步刷新；
- 情节素材库改为先选作品、再查看作品内情节；`GET /api/rag/scenes` 支持 `book` 精确过滤；
- Agent 消息间距调整，思考结束自动收起。

## 四、接口与数据变更

新增表：

- `inspiration_sessions`
- `inspiration_messages`
- `inspiration_branches`
- `inspiration_chat_messages`
- `inspiration_cards`
- `inspiration_settings`
- `writing_tools_settings`

新增 / 调整接口：

- `POST /api/writing/novel/inspiration/stream`
- `GET /api/bili/transcripts`
- `GET /api/bili/transcripts/{id}`
- `DELETE /api/bili/transcripts/{id}`
- `GET /api/rag/scenes` 增加 `book` 参数
- `WritingService` 的 optimize / draw 支持 `settings`

新表由服务端启动时根据 `schema.json` 自动创建，不需要手工迁移。

## 五、兼容性与风险

- 旧数据浏览深链接、旧 Agent 会话、旧消息仍可读取；
- 新表为空不影响现有业务；未重启后端时，新接口与新表不可用；
- 数据浏览默认隐藏内部字段，仍可通过「显示全部字段」查看；
- Agent 恢复不自动重放工具，避免写库 / 下载 / 文件生成等操作重复执行；
- 输出恢复以检查点为准，服务端异常退出最多丢最后约 800ms 增量；
- 本变更不涉及 App 代码、App 数据库、版本号、APK 或 `latest.json`。

## 六、验证记录

- 数据浏览：当前设备 31 张表 / 5755 行；选中「章节」展开 5327 行不跳页；跨库切换正常；
- 查看大纲：5 个大事件 / 15 个小事件，取消 2 个后显示 3 个 / 9 个；只选 1 个显示 1 个 / 3 个；
- 查看正文：3936 字正文完整显示；
- 小说灵感：3 候选并行、采用、版本切换、合并、聊天、导入 15 个事件中的 1 个、人物卡、设置保存均通过；
- B 站记录：3 条 → 删除后 2 条；存储单测 2 项通过；
- 写作 AI 设置：`max_tokens=16` 时输出截断到 26 字，确认设置生效；
- Agent 恢复：构造 running 运行 + 执行中工具 + 等待中提问，重启服务端后运行变 interrupted、正文保留、工具 error、提问 timeout；
- 前端 `pnpm run build`（含 `vue-tsc --noEmit`）通过；后端 `mvnw.cmd -q -DskipTests compile` 通过；
- 浏览器端无运行时错误，临时测试数据已清理。

## 七、上线与回滚

上线：

1. 构建并部署最新 `web/app/dist`；
2. 重启 `web/server-java`，让新表与新接口生效；
3. 打开 `/browse` 验证内容选择与展开，打开 Agent 面板验证历史消息与「继续任务」。

回滚：

1. 回滚前端 `dist` 到上一版本；
2. 回滚后端代码并重启；
3. 新增表可保留，不影响旧逻辑；无需删除数据。

## 八、影响文件

| 范围 | 主要文件 |
|------|----------|
| 数据浏览 | `web/app/src/views/BrowseView.vue`、`dataLabels.ts`、`router/index.ts`、`layouts/AppLayout.vue` |
| 大纲 / 正文 | `web/app/src/views/writing/OutlineReadView.vue`、`OutlineSelectView.vue`、`ChapterReadView.vue` |
| 小说灵感 | `web/app/src/views/writing/InspirationView.vue` 等、`web/server-java/.../InspirationAiService.java` |
| B 站 / 下载 | `web/app/src/views/BiliTranscriptView.vue`、`DownloadsView.vue`、`web/server-java/.../BiliTranscriptStore.java` |
| 写作 AI 设置 | `web/app/src/views/writing/WritingToolsView.vue`、`AiSettingsDrawer.vue`、`novelSettings.ts`、`WritingService.java` |
| Agent 恢复 | `web/app/src/stores/agent.ts`、`components/agent/AgentPanel.vue`、`AgentRunRecoveryRunner.java` |
| 数据库 | `web/server-java/src/main/resources/schema.json` |
| 文档 | `开发日志.md` |

## 九、评审结论

- 评审人：待填写
- 评审结论：待评审
- 上线窗口：待确认