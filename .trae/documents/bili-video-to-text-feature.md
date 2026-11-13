# B站视频转文字功能实现计划

## Context

在网页端（web/app + web/server-java）新增功能：输入B站视频链接，提取视频文字稿。
策略：**优先官方字幕**（用户上传字幕 + B站 AI 字幕 ai-zh）；**拿不到字幕时下载音频 → 本地 faster-whisper 转写**（Python 子进程）。

用户已确认的决策：
- ASR 兜底：本地 faster-whisper（用户机器 Python：`D:\tools\python3.10.10\python.exe`）
- SESSDATA：网页设置界面配置（存服务端数据目录），环境变量 `BILIBILI_SESSDATA`/`.env` 兜底
- UI：写作主页新功能入口 + 独立页面

数据流：前端输入链接 → `POST /api/bili/resolve`（视频信息+分P+第一P字幕列表）→ 用户选分P/字幕源 → `POST /api/bili/extract`（SSE：字幕路径逐条推 delta；ASR 路径推 stage/progress/delta）→ done。

## 后端（web/server-java）

### 新增文件（包 com.deepseekapp.webserver 下）

| 文件 | 职责 |
|---|---|
| `service/WbiSigner.java` | WBI 签名：nav 接口取 img/sub key（内存缓存 12h）→ 混淆表重排 → query+wts 做 MD5 → w_rid。注意 percent-encoding 与标准 URLEncoder 三处差异：`+`→`%20`、`*`→`%2A`、`%7E`→`~` |
| `service/BiliApiService.java` | B站 API HTTP 客户端（Java 21 HttpClient，统一 UA/Referer/Cookie）：fetchView(bvid)、fetchPlayerInfo(aid,cid,sessdata)→subtitles[]、fetchSubtitleLines(url)、bestAudioUrl(aid,cid)（playurl fnval=16 取最低码率 dash.audio）、downloadAudio(url,path,进度回调)、checkSessdata(nav 校验)；412/429 统一转风控提示 |
| `service/BiliSettingsService.java` | SESSDATA 读写：`dataDir/bili/settings.json` 原子写入；来源链 settings.json → 环境变量 → .env；info() 脱敏；save() 用 nav 校验（无效抛 400 不落盘） |
| `service/WhisperAsrService.java` | faster-whisper 子进程管理：脚本从 classpath 解压到 dataDir/bili/（MD5 比对更新）；stdout JSON 行协议（info/segment/done）；Semaphore(1) 串行；取消时 destroyForcibly；import 探测缓存 + 未安装友好提示（含完整 pip install 命令）；stdout 10 分钟无输出看门狗 |
| `service/BiliTranscriptService.java` | 编排：resolve（正则提 BV 号）、subtitles、streamExtract 决策链（有字幕→下载字幕逐条 delta；无字幕→时长校验→下载音频进度→whisper 转写进度+delta；临时音频文件 finally 删除） |
| `api/BiliController.java` | 瘦接口层：POST /resolve、POST /subtitles、POST /extract（SSE，复刻 WritingController 写法）、GET/PUT /settings |
| `src/main/resources/bili/whisper_transcribe.py` | 转写脚本：`--audio --model` 参数，cpu/int8/zh/vad_filter；stdout 逐 segment 输出 JSON 行；`sys.stdout.reconfigure(encoding='utf-8')` |
| `util/DotEnv.java` | .env 读取工具（逻辑取自 WritingService.dotEnv()，不改 WritingService） |

### 修改的现有文件

- `config/AppProperties.java` + `application.yml`：新增 `bili-python`（默认 `D:\tools\python3.10.10\python.exe`）、`bili-whisper-model`（默认 small）、`bili-max-video-minutes`（默认 180）
- 复用不动：`web/Api.java`、`ApiException`、`AuthFilter`（/api/bili/* 自动纳入）、`util/Json.java`

## 前端（web/app）

### 新增/修改文件

| 文件 | 改动 |
|---|---|
| `src/views/writing/BiliTranscriptView.vue` | 新增主页面，状态机 idle→resolved→extracting→done/error |
| `src/router/index.ts` | 加 `/writing/bili` 路由 |
| `src/views/WritingView.vue` | features 数组加入口（icon: VideoPlay） |
| `src/api/client.ts` | StreamHandlers 加 `onProgress`；handleBlock 加 progress 分支 |
| `src/api/types.ts` | BiliVideoInfo/BiliPage/BiliSubtitle/BiliSettingsInfo/BiliExtractPayload/BiliExtractDoneInfo 等类型 |
| `src/api/index.ts` | `api.bili.{resolve,subtitles,extract,settings,saveSettings}` |

### 页面交互

1. 输入区：链接/BV号 + 解析按钮
2. 视频信息卡：标题/UP主/时长 + 分P chips（切换刷新字幕列表）
3. 字幕源区：有字幕 → chips 单选（AI 字幕带标签）；无字幕 → warning alert（提示 SESSDATA 未配置/已过期/确实无字幕）
4. 提取按钮（auto：有字幕用字幕，无字幕本地转写）+ 停止按钮（abort）
5. 进度区：stage 文本 + el-progress（percent）+ 副行文本 + 实时文本流滚动
6. 结果区：全文 + 字数/耗时 + 复制 + 下载 txt（前端 Blob）
7. SESSDATA 设置卡片（页内折叠，默认收起）：password 输入 + 保存并校验（F12 复制指引）

SSE 事件：stage{index,total,label} / progress{percent,text} / delta{text} / done{source,elapsedMs,chars} / error{error}。

## 实现顺序（每步一个 commit，可独立验证）

| 步骤 | 内容 | 验证 |
|---|---|---|
| 1 | 后端配置项 + WbiSigner + BiliApiService(fetchView) + resolve 接口 | 启动服务 curl resolve 真实视频，确认 title/pages；非链接返回 400 |
| 2 | DotEnv + BiliSettingsService + settings GET/PUT | curl 保存真实 SESSDATA → valid+uname；假值 → 400；确认 settings.json 落盘 |
| 3 | 字幕链路：fetchPlayerInfo/listSubtitles/fetchSubtitleLines + subtitles 接口 | **WBI 签名首验**：带 SESSDATA resolve 有 AI 字幕的视频 → subtitles 含 ai-zh（code==0 即签名正确） |
| 4 | whisper 脚本 + WhisperAsrService + playurl/downloadAudio + streamExtract + extract SSE 接口 | 先手工跑脚本验证 stdout JSON；curl -N extract 无字幕短视频，肉眼确认 stage→progress→delta→done；改错 python 路径验证提示；中途 Ctrl+C 确认 python 进程被杀 |
| 5 | 前端骨架：client.ts/types/api/路由/入口/页面（输入+解析+设置卡片） | `pnpm type-check`；浏览器走通解析、切分P、保存 SESSDATA |
| 6 | 前端提取全流程：字幕 chips、进度、结果区、停止 | 浏览器跑两条真实路径（有字幕视频秒出稿；无字幕短视频看进度→实时文本→done）+ 验证停止；`pnpm build` 收尾 |

后端启动用 `mvn spring-boot:run`；前端 `pnpm dev`。验证遵守 AGENTS.md：同一检查只跑一次，不重复测试。

## 风险与对策

1. **WBI 签名错误**：percent-encoding 三处修正必须做；验证法 = 真调 player/wbi/v2 返回 code==0；-403 优先查编码与混淆表
2. **B站风控 412**：统一拦截转友好提示；nav key 内存缓存降频
3. **SESSDATA 过期**：保存时 nav 校验；resolve 返回 sessdataConfigured；无字幕时前端列出两种可能
4. **faster-whisper 未安装**：探测缓存 + ApiException(503) 带 `"D:\tools\python3.10.10\python.exe" -m pip install faster-whisper` 完整命令
5. **首次模型下载（small 约 460MB）**：stderr 进度转 progress 事件提示
6. **视频过长**：bili-max-video-minutes 上限 413；临时音频 finally 清理；转写 Semaphore(1) 防多任务打死 CPU
7. **Windows 编码**：脚本 stdout UTF-8；Java 读子进程流统一 UTF-8
8. **取消泄漏**：浏览器 abort → 写流 IOException → finally destroyForcibly+waitFor

## 第一期明确不做

av 号/番剧/充电专属视频、弹幕/评论/简介、字幕翻译、多语言（固定 zh）、SRT/时间戳导出（只出纯文本）、whisper 模型与 Python 路径的网页配置（走 yml/env）、批量链接、写入小说库联动、buvid3/bili_jct 完整 Cookie、代理支持、断点续传、SSE 工具类重构。

## 发版约束（AGENTS.md）

全程不改版本号、不构建 release；真机验证如需要只用 debug。
