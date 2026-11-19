# RAG 情节素材库

网页端新增的「情节素材库」：把小说 txt 拆成可复用的情节素材，生成向量后存入 Elasticsearch；写作时可以按语义检索参考情节，再让 DeepSeek 仿写新桥段。

## 1. 依赖

- **Elasticsearch 8.x**：本项目专用 Docker 容器 `novel-rag-es`，宿主机端口 `9221`（容器内 `9200`），定义在 `web/rag/docker-compose.yml`。
- **阿里云百炼 embedding**：OpenAI 兼容接口，默认模型 `qwen3.7-text-embedding-flash`，默认维度 `1024`（该模型还支持 768/512/256）。
- **DeepSeek**：沿用服务端已有的 `DEEPSEEK_API_KEY`，用于情节拆解和仿写正文。

## 2. 配置

在 `web/server/.env` 增加：

```env
DASHSCOPE_API_KEY=你的百炼密钥
DASHSCOPE_EMBEDDING_MODEL=qwen3.7-text-embedding-flash
DASHSCOPE_EMBEDDING_DIM=1024
RAG_ES_URL=http://127.0.0.1:9221
RAG_ES_INDEX=novel_rag_scenes
```

可选：

```env
RAG_CHUNK_CHARS=8000          # 旧版兼容项，现由窗口参数替代
RAG_WINDOW_CHARS=12000        # 单个情节弧窗口目标字数（默认 12000）
RAG_OVERLAP_CHARS=1500        # 相邻窗口重叠字数（默认 1500）
RAG_EXTRACT_CONCURRENCY=4     # 并行提炼窗口数（默认 4）
RAG_MAX_UPLOAD=64MB
```

「情节素材库 → 导入小说 → 设置」里可以改这三项和「分块完成后手动开始提炼」开关（默认开启），设置保存在数据目录 `rag/settings.json`，优先级高于环境变量。

如果 Elasticsearch 容器没有运行：

```powershell
docker compose -f web/rag/docker-compose.yml up -d
```

`.env` 已被 `web/.gitignore` 忽略，密钥不会进入仓库。

## 3. 导入流程（两阶段）

1. **解析/分块**（不调用 LLM）：
   - 格式检测：空行分段 / 单换行分段 / 整篇无换行，按行数与段落特征自动选择；
   - 段落重建：超长段落先按句末标点切开，保证窗口不会从句子中间开始；
   - 章节识别：`第X回/章/节`、`Chapter N`、`数字标题` 多套候选，按命中数和编号单调性选最合适的一套；识别不到章节时退化为按段落组窗口；
   - 情节弧窗口：识别到章节时按章组窗口（不跨章切），否则按段落组窗口；窗口目标 `RAG_WINDOW_CHARS`（默认 12000），相邻窗口追加 `RAG_OVERLAP_CHARS`（默认 1500）的上一窗口末尾文本作为重叠前缀，保证跨窗口的完整情节至少有一个窗口能完整看到；
   - 单章过长（> 2 倍窗口字数）时在章内部再按句末切子窗口。
2. **手动确认（默认开启）**：分块完成后任务停在 `waiting`，网页显示格式、章节数、窗口数和每个窗口的原文预览，可改窗口/重叠/并行数后「重新划分」，确认无误再点「开始提炼」。关闭该开关时解析完自动进入提炼。
3. **并行提炼**：按窗口分批（批次大小 = `RAG_EXTRACT_CONCURRENCY`，默认 4）并行调用 DeepSeek；每个窗口 prompt 带上一个批次最后一条情节摘要作为「续接状态」，并要求模型不要重复上一批内容、不要补全不完整情节。每个窗口的模型原始返回都会保存，网页里点开窗口即可查看。
4. **合并去重**：相邻窗口的重叠内容可能重复抽出同一情节，按「标题相似度 + plot 字符二元组 Jaccard 相似度」做相邻窗口去重，`mergedCount` 记录合并掉的条数。
5. **向量化 + 入库**：百炼 embedding（8 条一批、最多 4 批并行）生成 1024 维向量；按作品名覆盖旧素材，批量写入 ES。
6. 任务是后台任务：网页轮询 `/api/rag/jobs/{id}` 显示进度；切换页面后重新进入会从 `/api/rag/jobs` 找回最近进行中的任务继续显示（服务重启后任务会丢失，需重新导入）。

## 4. 检索与仿写

- **检索**：把需求描述做 embedding，用 ES 8 的 kNN 取相似情节；可选按标签过滤。
- **仿写**：取 Top N 参考情节，将「情节梗概 + 可复用结构」交给 DeepSeek，要求：
  - 只借鉴结构、冲突节奏和情绪曲线；
  - 不照抄原句、不复用参考中的人物姓名或专有名词；
  - 按用户需求重新设计人物与事件，输出小说正文。

## 5. 接口

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/rag/status` | ES / embedding / 统计状态 |
| GET | `/api/rag/settings` | 导入设置（手动开始/窗口/重叠/并行） |
| PUT | `/api/rag/settings` | 保存导入设置（部分字段） |
| POST | `/api/rag/analyze` | multipart 上传（file、book），只解析与分块，返回任务与窗口 |
| POST | `/api/rag/jobs/{id}/resplit` | 重新分块（未开始提炼时可用）：windowChars/overlapChars/concurrency |
| POST | `/api/rag/jobs/{id}/start` | 开始提炼（并行 + 合并 + embedding + 入库） |
| GET | `/api/rag/jobs` | 最近任务列表（运行中的在前，切页后恢复用） |
| GET | `/api/rag/jobs/{id}` | 任务详情（含各窗口状态） |
| GET | `/api/rag/jobs/{id}/windows/{index}` | 单窗口详情：原文、DeepSeek 原始输出、解析出的情节 |
| POST | `/api/rag/import` | 兼容旧接口：上传并立即开始提炼（忽略手动开关） |
| GET | `/api/rag/scenes` | 素材列表（page、pageSize、q） |
| POST | `/api/rag/search` | 语义检索（query、size、tags） |
| POST | `/api/rag/imitate` | 检索并仿写（query、size、tags、style、extra） |
| DELETE | `/api/rag/books?book=` | 删除一部作品的素材 |

## 6. 索引结构

```json
{
  "title": "text(ik_max_word) + keyword",
  "book": "keyword",
  "plot": "text(ik_max_word)",
  "excerpt": "text(ik_max_word)",
  "tags": "keyword[]",
  "characters": "keyword[]",
  "sceneType": "keyword",
  "emotion": "keyword",
  "reusable": "text(ik_max_word)",
  "embedding": "dense_vector(dims=1024, cosine)",
  "createdAt": "date"
}
```

索引在首次调用 `/api/rag/status` 或导入时自动创建；如果容器没有安装 ik 分词插件，会自动退回 `standard`。
