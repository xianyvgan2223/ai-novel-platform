# deepseekapp · Web 端

手机 App（Flutter + sqflite）与网页共享同一套数据的 Web 数据台。

- **看**：在浏览器里浏览手机上的对话、小说大纲、章节正文、角色卡、跑团日志
- **改**：直接编辑任意表的任意字段，改动会记录到变更日志
- **搬**：把 App 导出的 `deepseek.db` 上传进来，也可以把网页上的数据导出成 `.db` 再导入回 App

> 本目录是**为后续开发准备的地基**：数据模型、同步协议、服务端、前端骨架都已跑通并有自检脚本。

---

## 1. 目录结构

```
web/
├─ README.md                 ← 你正在看的文件
├─ docs/
│  ├─ 使用指南.md            ⭐ 怎么启动、怎么把手机数据搬进来、怎么导回去
│  ├─ 数据模型.md            24 张表的字段、外键、时间格式、与 App 的同步维护方式
│  └─ 同步协议.md            增量同步协议、接口定义、冲突裁决、App 端接入清单
├─ server/                   Node + Express + SQLite 同步服务（零原生依赖）
│  ├─ src/
│  │  ├─ schema.js           ⭐ App 两个库的完整表结构（Web 端唯一权威副本）
│  │  ├─ db.js               SQLite 访问层（唯一直接依赖驱动的文件）
│  │  ├─ syncStore.js        ⭐ 变更日志、行版本、冲突裁决
│  │  ├─ config.js / http.js 配置与统一响应格式
│  │  ├─ routes/             meta / data / sync / transfer 四组接口
│  │  └─ services/           importer（导入 .db）/ exporter（导出 .db）
│  ├─ scripts/               命令行导入导出 + 两套自检脚本
│  └─ data/                  运行时生成：deepseek.db、novel.db、sync.db
└─ app/                      Vue 3 + Element Plus + Vite + TypeScript 前端
   └─ src/
      ├─ api/                接口封装与类型定义
      ├─ stores/server.ts    表目录 / 统计 / 同步状态
      ├─ layouts/            左侧导航布局
      └─ views/              总览、会话、会话详情、数据浏览、同步与备份
```

---

> **第一次用？先看 [docs/使用指南.md](docs/使用指南.md)** —— 从启动到把手机数据搬进搬出，一步步都写了。

## 2. 快速开始

> **Windows 用户请注意**：系统自带的 **Windows PowerShell 5.1 不支持 `&&`**，
> 直接粘贴 `cd web/app && npm run dev` 会报「标记"&&"不是此版本中的有效语句分隔符」。
> 请**一行一行执行**下面的命令（或用 `;` 分隔，例如 `cd web/app; npm run dev`）。
> 若想用 `&&`，可以改装 PowerShell 7+ 或 Git Bash。

### 2.1 启动同步服务（必须先启动）

```bash
cd web/server
npm install          # 仅一个依赖：express（SQLite 用 Node 内置的 node:sqlite）
npm start            # 默认 http://localhost:3210
```

启动后终端会分门别类地打印网卡地址，认准「**手机请填**」那一行即可；
虚拟网卡（WSL / VMware / 加速器）会被单独列出来并标注「手机连不上」，不用理会。

要求 **Node ≥ 22.5**（推荐 22 LTS / 24）。本项目在本机 Node v24.11.1 上验证通过。

### 2.2 前端开发模式（热更新）

```bash
cd web/app
npm install
npm run dev          # http://localhost:5173，/api 已自动代理到 3210
```

### 2.3 生产模式（单端口、同源）

```bash
cd web/app
npm run build                    # 产物输出到 web/app/dist
cd ../server
npm start                        # 服务端会自动托管 dist，直接访问 http://localhost:3210
```

### 2.4 想先看看界面长什么样

```bash
cd web/server
npm run seed                             # 生成演示数据到 data-demo/
$env:DATA_DIR='data-demo'; npm start      # 用演示数据启动
```

演示数据写在 `data-demo/` 目录，**不会碰你的真实数据**。

---

## 3. 数据怎么进来、怎么回去

### 路径 A：直接同步（推荐）

手机 App「设置 → 数据同步」里填上服务地址，点「立即同步」即可双向同步，不用来回导文件。
App 端代码在 `lib/features/sync/`；完整步骤与连不上时的排查见
[docs/使用指南.md](docs/使用指南.md) 第二节。

### 路径 B：用 .db 文件搬运（备用）

| 方向 | 操作 |
| --- | --- |
| 手机 → Web | App 内「设置 → 导出数据库」得到 `deepseek_backup.db` → 网页「同步与备份 → ① 导入」上传 |
| Web → 手机 | 网页「同步与备份 → ② 导出」下载 `deepseek_web-*.db` → 拷到手机 → App 内「设置 → 导入数据库」 |

导出的文件与 App 表结构完全一致（17 张表、`user_version = 33`、不含任何同步元数据），
并且默认会清空 `apiKey` / `baidu_api_key`，方便直接分享或存放。

⚠️ `novel.db`（小说游戏模块）不在 App 的导出范围内，只能走路径 A。

---

## 4. 界面说明

| 页面 | 用途 |
| --- | --- |
| **总览** | 各模块数据量统计、同步服务状态、两个数据库文件与全部表的行数/最近变更 |
| **对话会话** | 会话列表（标题 + 摘要 + 末条消息），点进去看完整对话 |
| **会话详情** | 消息按对话气泡展示，支持渲染 Markdown、思考过程折叠、联网搜索来源 |
| **数据浏览** | **通用表浏览器**：24 张表全部可浏览、搜索、排序、编辑、新增、删除；表结构由服务端 `/api/catalog` 驱动，App 加表后前端不用改 |
| **同步与备份** | 导入 / 导出 .db、设备与同步水位、冲突记录 |

界面基于 Element Plus 做了整体主题定制（模板见 `app/src/styles/main.css`）：
统一的设计令牌（颜色 / 圆角 / 阴影 / 间距）、卡片化布局、表格去掉竖线只留浅色分隔。

---

## 5. 常用命令

在 `web/server` 目录下：

| 命令 | 作用 |
| --- | --- |
| `npm start` | 启动服务 |
| `npm run dev` | 启动服务并监听文件变化自动重启 |
| `npm run seed` | 生成演示数据（写入 `data-demo/`，**不会碰真实数据**），用来预览界面 |
| `npm run smoke` | **端到端自检（32 项）**：建库 → 导入 → 拉取 → 冲突 → 级联删除 → 导出校验 |
| `npm run http-test` | **接口自检（41 项）**：真实拉起服务，逐个验证路由与鉴权 |
| `npm run import-db -- "C:\\path\\备份.db" deepseek merge` | 命令行导入，不需要开服务 |
| `npm run export-db -- deepseek ./out` | 命令行导出（加 `--keep-secrets` 保留 API Key） |

在 `web/app` 目录下：`npm run dev` / `npm run build` / `npm run type-check`。

---

## 6. 接口速查

统一响应格式：成功 `{ ok: true, data, meta? }`，失败 `{ ok: false, error }`。
若 `server/.env` 里设置了 `API_TOKEN`，除 `/api/health` 外的接口都需要请求头 `x-api-token`。

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/health` | 健康检查（**无需令牌**，手机端可用它探测服务是否在线） |
| GET | `/api/catalog` | 全部表结构与列元信息（前端据此自动渲染任意表） |
| GET | `/api/stats` | 各表行数与最近变更时间 |
| GET | `/api/data/:db/:table` | 分页列表，支持 `q` 搜索、`orderBy`/`dir` 排序、任意列等值过滤、`full=1` 取全文 |
| GET/POST/PUT/DELETE | `/api/data/:db/:table[/:pk]` | 单行增删改查（删除会级联并记录日志） |
| GET | `/api/sync/overview` | 设备列表 + 冲突 + 统计 |
| GET | `/api/sync/pull?since=0&deviceId=x` | 增量拉取变更 |
| POST | `/api/sync/push` | 推送本地变更 |
| POST | `/api/transfer/import?db=deepseek&mode=merge` | 上传 `.db`（二进制请求体） |
| GET | `/api/transfer/export/deepseek` | 下载可被 App 导入的 `.db` |

`:db` 取 `deepseek` 或 `novel`。

---

## 7. 设计要点（为什么这样做）

1. **规范库就是 App 的库**：服务端存的两份 SQLite 文件与手机端表结构完全一致，
   同步元数据（设备、行版本、变更日志）单独放在 `sync.db`。
   好处是「导出」只是复制文件，不需要任何转换，也就不会漏字段。
2. **主键段位隔离**：手机端用 `AUTOINCREMENT`（从 1 开始），Web 端新建的行统一用 **10 亿以上**的主键，
   两边永远不会撞 ID，App 端不需要为了同步改主键策略。
3. **一切写入都留痕**：Web 端和文件导入的每一次增删改都会写 `change_log`，
   所以手机端随时能按 `seq` 追平，不存在「网页改了手机上不知道」的情况。
4. **表结构只维护一份**：`server/src/schema.js` 同时生成建表 SQL、驱动前端表单、决定导入校验规则。
   App 升级表结构时只需要改这一处。

---

## 8. 已验证内容

| 项目 | 结果 |
| --- | --- |
| `npm run smoke` | 32 项全部通过（含导入幂等、冲突裁决、级联删除、导出文件可被 App 使用） |
| `npm run http-test` | 41 项全部通过（含鉴权、分页搜索、上传下载、路由兜底） |
| `npm run build`（前端） | `vue-tsc` 类型检查 + `vite build` 通过 |
| 真实旧库导入 | 仓库内那份 `user_version = 1` 的老 `deepseek.db` 可正常导入并给出缺表/低版本告警 |
| SPA 托管 | 服务端托管 `app/dist`，深链接（如 `/sync`）刷新可正常回退到前端路由 |

---

## 9. 已知限制与注意事项

- **当前只支持一台手机 + Web**。两台手机各自新建的记录不会撞 ID，但「同一行被两台设备同时修改」时，
  服务端默认保留自己的版本并把冲突写入 `conflicts` 表（网页「同步与备份」页可查看）。
  如需真正的多端合并，需要把主键换成 UUID 方案（见 `docs/同步协议.md` 末尾的升级路径）。
- **不要用 App 的「覆盖导入」把旧备份导回来**：那会把网页上的新数据整库替换掉。
- **不要两台设备同时开「覆盖模式导入」**，语义是「清空服务端再灌入」。
- **`data/` 目录是真实数据**，已加入 `.gitignore`；备份它就是备份全部数据（`deepseek.db`、`novel.db`、`sync.db` 三个文件一起拷）。
- **公网部署必须设置 `API_TOKEN`**，否则任何人都能读写你的数据。
- 变更日志会随使用增长，网页「同步与备份 → 清理旧日志」可裁掉所有设备都已拉取过的部分。
