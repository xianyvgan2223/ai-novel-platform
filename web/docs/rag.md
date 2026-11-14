# RAG 情节素材库

网页端新增的「情节素材库」：把小说 txt 拆成可复用的情节素材，生成向量后存入 Elasticsearch；写作时可以按语义检索参考情节，再让 DeepSeek 仿写新桥段。

## 1. 依赖

- **Elasticsearch 8.x**：本项目专用 Docker 容器 `novel-rag-es`，宿主机端口 `9221`（容器内 `9200`），定义在 `web/rag/docker-compose.yml`。
- **阿里云百炼 embedding**：OpenAI 兼容接口，默认模型 `text-embedding-v3`，默认维度 `1024`。
- **DeepSeek**：沿用服务端已有的 `DEEPSEEK_API_KEY`，用于情节拆解和仿写正文。

## 2. 配置

在 `web/server/.env` 增加：

```env
DASHSCOPE_API_KEY=你的百炼密钥
DASHSCOPE_EMBEDDING_MODEL=text-embedding-v3
DASHSCOPE_EMBEDDING_DIM=1024
RAG_ES_URL=http://127.0.0.1:9221
RAG_ES_INDEX=novel_rag_scenes
```

可选：

```env
RAG_CHUNK_CHARS=8000
RAG_MAX_UPLOAD=64MB
```

如果 Elasticsearch 容器没有运行：

```powershell
docker compose -f web/rag/docker-compose.yml up -d
```

`.env` 已被 `web/.gitignore` 忽略，密钥不会进入仓库。

## 3. 导入流程

1. 网页打开「情节素材库 → 导入小说」，选择 `.txt`，可填写作品名；
2. 后端按段落切成约 8000 字的片段（超过上限会按段落拆开）；
3. DeepSeek 对每个片段拆出 1~5 条情节，返回：
   - `title`：情节标题
   - `plot`：200~450 字的情节梗概
   - `excerpt`：原文摘录
   - `tags` / `characters` / `sceneType` / `emotion`
   - `reusable`：可复用的戏剧结构
4. 百炼 `text-embedding-v3` 对「标题 + 梗概 + 标签 + 人物 + 场景 + 情绪 + 可复用结构」生成向量；
5. 删除同名作品的旧素材，批量写入 ES 索引 `novel_rag_scenes`；
6. 导入是后台任务，前端轮询 `GET /api/rag/jobs/{id}` 显示进度。

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
| POST | `/api/rag/import` | multipart 上传 txt（file、book） |
| GET | `/api/rag/jobs/{id}` | 导入任务进度 |
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
