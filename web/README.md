# deepseekapp · Web 端

手机 App（Flutter + sqflite）与网页共享同一套数据结构的 Web 数据台。

- **看**：在浏览器里浏览手机上的对话、小说大纲、章节正文、角色卡、跑团日志
- **改**：直接编辑任意表的任意字段，改动会记录到变更日志
- **搬**：把 App 导出的 `deepseek.db` 上传进来，也可以把网页上的数据导出成 `.db` 再导入回 App

> **数据按设备隔离**：每台移动端设备在服务端有自己独立的一套库与变更日志，
> **不同设备的数据不会互相同步、不会互相覆盖**。网页右上角可切换要查看哪台设备。

> 本目录是**为后续开发准备的地基**：数据模型、同步协议、服务端、前端骨架都已跑通并有自检脚本。

---

## 1. 目录结构

```
web/
├─ README.md                 ← 你正在看的文件
├─ docs/
│  ├─ 使用指南.md            ⭐ 怎么启动、USB 隧道 / Wi-Fi 怎么连、多台设备怎么用、怎么导回去
│  ├─ 数据模型.md            24 张表的字段、外键、时间格式、与 App 的同步维护方式
│  └─ 同步协议.md            增量同步协议、设备隔离、连接通道、接口定义、冲突裁决、App 端接入清单
├─ server/                   Node + Express + SQLite 同步服务（零原生依赖）
│  ├─ src/
│  │  ├─ schema.js           ⭐ App 两个库的完整表结构（Web 端唯一权威副本）
│  │  ├─ db.js               ⭐ SQLite 访问层 + 每台设备一个数据槽位（隔离的核心）
│  │  ├─ syncStore.js        ⭐ 按设备读写：变更日志、行版本、冲突裁决
│  │  ├─ config.js / http.js 配置与统一响应格式
│  │  ├─ middleware/         deviceContext（x-device-id → 当前设备）
│  │  ├─ routes/             meta / data / sync / transfer 四组接口
│  │  └─ services/           importer（导入 .db）/ exporter（导出 .db）
│  ├─ scripts/               命令行导入导出 + USB 隧道 + 三套自检脚本（smoke / isolation / http-test）
│  └─ data/
│     ├─ devices/<设备号>/   每台设备自己的 deepseek.db、novel.db、sync.db
│     └─ sync.db             全局登记表（设备清单 / 待办请求 / 冲突留档）
└─ app/                      Vue 3 + Element Plus + Vite + TypeScript 前端
   └─ src/
      ├─ api/                接口封装与类型定义（自动带 x-device-id）
      ├─ stores/device.ts    ⭐ 当前选中的设备（localStorage 持久化）
      ├─ stores/server.ts    设备 / 表目录 / 统计 / 同步状态
      ├─ layouts/            左侧导航 + 右上角设备切换器
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

**电脑上点**：网页右上角「同步手机」→ 手机 App 开着就会自动响应并同步。
**手机上点**：左上角 ☰ 菜单 → 底部「数据同步」，点一下直接同步。
首次需要在「设置 → 数据同步」里填一次服务地址，之后会自动记住（也可以跳过，同步时会自动扫描局域网找电脑）。
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
| **总览** | 各模块数据量统计、同步服务状态、当前设备与设备数量、两个数据库文件与全部表的行数/最近变更 |
| **对话会话** | 会话列表（标题 + 摘要 + 末条消息），点进去看完整对话 |
| **会话详情** | 消息按对话气泡展示，支持渲染 Markdown、思考过程折叠、联网搜索来源 |
| **数据浏览** | **通用表浏览器**：24 张表全部可浏览、搜索、排序、编辑、新增、删除；表结构由服务端 `/api/catalog` 驱动，App 加表后前端不用改 |
| **同步与备份** | 导入 / 导出 .db、当前设备、设备清单（行数/水位/冲突）、冲突记录 |

右上角有**设备切换器**（顶栏「当前设备」）：所有页面显示与编辑的都是它选中的那台设备的数据，
下拉里还能直接删除某台设备在服务端的数据。设备数量每 15 秒自动刷新，
手机第一次同步后会自动出现在列表里。

界面基于 Element Plus 做了整体主题定制（模板见 `app/src/styles/main.css`）：
统一的设计令牌（颜色 / 圆角 / 阴影 / 间距）、卡片化布局、表格去掉竖线只留浅色分隔。

---

## 5. 常用命令

在 `web/server` 目录下：

| 命令 | 作用 |
| --- | --- |
| `npm start` | 启动服务 |
| `npm run dev` | 启动服务并监听文件变化自动重启 |
| **`npm run usb`** | **建立 USB 隧道（推荐）**：`adb reverse` 把手机的 `127.0.0.1:3210` 接到电脑，手机不看 Wi-Fi、不受防火墙影响。守护式运行，隧道掉了自动重建，Ctrl+C 退出 |
| `npm run seed` | 生成演示数据（写入 `data-demo/`，**不会碰真实数据**），用来预览界面 |
| `npm run smoke` | **端到端自检（48 项）**：建库 → 导入 → 拉取 → 冲突 → 级联删除 → **两台设备隔离** → 导出校验 |
| `npm run isolation` | **隔离与升级自检（18 项）**：v1→v2 迁移两种情形 + 两台设备同主键互不干扰 |
| `npm run http-test` | **接口自检（71 项）**：真实拉起服务，逐个验证路由、鉴权与 `x-device-id` 隔离 |
| `npm run test:all` | 上面三套一起跑 |
| `npm run import-db -- "C:\\path\\备份.db" deepseek merge` | 命令行导入到 Web 控制台槽位，不需要开服务 |
| `npm run export-db -- deepseek ./out` | 命令行导出（加 `--keep-secrets` 保留 API Key） |

在 `web/app` 目录下：`npm run dev` / `npm run build` / `npm run type-check`。
在仓库根目录：`flutter test test/sync_channel_test.dart` 验证手机端的连接通道解析。

---

## 6. 接口速查

统一响应格式：成功 `{ ok: true, data, meta? }`，失败 `{ ok: false, error }`。
若 `server/.env` 里设置了 `API_TOKEN`，除 `/api/health` 外的接口都需要请求头 `x-api-token`。

**网页侧的业务接口还要带 `x-device-id`** 指定操作哪台设备（不带则默认 `web-console`）；
设备号必须是已登记的，否则返回 404 并列出可用设备。

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/health` | 健康检查（**无需令牌**，手机端可用它探测服务是否在线） |
| GET | `/api/net` | 这台电脑有哪些地址可给手机连（USB 隧道 / 局域网 / 虚拟网卡分类 + 提示） |
| GET | `/api/catalog` | 全部表结构与列元信息（前端据此自动渲染任意表） |
| GET | `/api/stats` | **当前设备**的各表行数与最近变更时间 + 设备清单 |
| GET | `/api/data/:db/:table` | 分页列表，支持 `q` 搜索、`orderBy`/`dir` 排序、任意列等值过滤、`full=1` 取全文 |
| GET/POST/PUT/DELETE | `/api/data/:db/:table[/:pk]` | 单行增删改查（删除会级联并记录日志） |
| GET | `/api/sync/devices` | 设备清单（行数 / 冲突 / 数据目录 / 待处理的旧库文件） |
| POST/DELETE | `/api/sync/devices[/:deviceId]` | 登记设备 / 删除该设备在服务端的数据 |
| GET | `/api/sync/overview` | 设备列表 + 冲突 + 当前设备统计 |
| GET | `/api/sync/pull?since=0&deviceId=x` | 增量拉取变更（**必须**指定 deviceId） |
| POST | `/api/sync/push` | 推送本地变更（只写进该 deviceId 的槽位） |
| POST | `/api/transfer/import?db=deepseek&mode=merge` | 上传 `.db`（二进制请求体），导入到当前设备 |
| GET | `/api/transfer/export/deepseek` | 下载**当前设备**可被 App 导入的 `.db` |

`:db` 取 `deepseek` 或 `novel`。

---

## 7. 设计要点（为什么这样做）

1. **每台设备一套库，连变更日志都分开**：`data/devices/<设备号>/` 下有它自己的
   `deepseek.db` / `novel.db` / `sync.db`。A 手机推上来的行只进 A 的 `change_log`，
   B 手机拉取时读的是 B 自己的日志 —— **物理上不可能拿到对方的数据**，
   两台手机的同 ID 行也就永远不会互相覆盖。全局 `sync.db` 只放跨设备的东西
   （设备清单、待办请求、冲突留档）。
2. **USB 数据线是最稳的连接通道**：`npm run usb` 用 `adb reverse` 把手机的
   `127.0.0.1:3210` 接到电脑上，走 USB 而不是网络 —— 不看 Wi-Fi、不经过路由器、
   不受 Windows 防火墙影响。手机端按「USB 隧道 → 历史地址 → 热点网关 → UDP 广播 →
   网段扫描」逐级兜底，所以两条路都能用，插上线就自动走隧道。
3. **规范库就是 App 的库**：每个槽位里的两份 SQLite 文件与手机端表结构完全一致，
   同步元数据单独放在该槽位的 `sync.db`。
   好处是「导出」只是复制文件，不需要任何转换，也就不会漏字段。
4. **主键段位隔离**：手机端用 `AUTOINCREMENT`（从 1 开始），Web 端新建的行统一用 **10 亿以上**的主键，
   同一台设备内部两边不会撞 ID，App 端不需要为了同步改主键策略。
5. **一切写入都留痕**：Web 端和文件导入的每一次增删改都会写该设备的 `change_log`，
   所以那台手机随时能按 `seq` 追平，不存在「网页改了手机上不知道」的情况。
6. **表结构只维护一份**：`server/src/schema.js` 同时生成建表 SQL、驱动前端表单、决定导入校验规则。
   App 升级表结构时只需要改这一处。

---

## 8. 已验证内容

| 项目 | 结果 |
| --- | --- |
| `npm run smoke` | 48 项全部通过（含导入幂等、冲突裁决、级联删除、**两台设备同 ID 行互不覆盖**、按设备导出） |
| `npm run isolation` | 18 项全部通过（v1→v2 迁移的两种情形、设备目录与冲突归属、真实隔离） |
| `npm run http-test` | 71 项全部通过（含鉴权、分页搜索、上传下载、`x-device-id` 隔离、未知设备 404、路由兜底） |
| 前端 `npm run build` | `vue-tsc` 类型检查 + `vite build` 通过；构建产物里可确认请求带上了 `x-device-id` |
| 真实老数据升级 | 用仓库里那份混库 + 老结构 `sync.db` 实测：自动补列、旧库不被误读、网页给出导入提示 |
| **USB 隧道全链路** | 真机实测：`adb reverse` 后手机 `curl http://127.0.0.1:3210/api/health` 能拿到服务信息；再走 `push` / `pull` 各一次，数据落进该设备自己的槽位、另一台设备查不到（404） |
| **隧道守护自愈** | 真机实测：外部清掉 `adb reverse` 后 2 秒内自动重建；残留隧道在下次启动时被识别并清掉重建 |
| `flutter test test/sync_channel_test.dart` | 地址归一化 / 通道识别 4 项恒通过；「能连上电脑」的断言在有服务时执行、无服务时自动跳过 |
| SPA 托管 | 服务端托管 `app/dist`，深链接（如 `/sync`）刷新可正常回退到前端路由 |

---

## 9. 已知限制与注意事项

- **设备之间不自动合并**（这是有意为之：不同移动端设备的数据不要同步）。
  要把数据从一台设备搬到另一台，在网页上导出源设备的 `.db`，切到目标设备后导入即可。
- **USB 隧道需要 adb 与 USB 调试授权**：手机要开「开发者选项 → USB 调试」并允许本电脑。
  没有 adb 时走 Wi-Fi 那条路即可，功能完全等价。
- **不要用 App 的「覆盖导入」把旧备份导回来**：那会把手机本地数据整库替换掉。
- **「覆盖模式导入」的语义是「清空当前设备在服务端的数据再灌入」**，只影响那一台设备，
  但同一时间不要对同一台设备开两次。
- **`data/` 目录是真实数据**，已加入 `.gitignore`；备份它就是备份全部数据
  （整个 `data/` 目录一起拷，其中 `devices/<设备号>/` 是各设备的数据）。
- **公网部署必须设置 `API_TOKEN`**，否则任何人都能读写**所有设备**的数据。
- 每台设备的变更日志会随使用增长，网页「同步与备份 → 清理本设备旧日志」按该设备的拉取水位裁剪。
- 从 v1 升级上来时，`data/deepseek.db` / `data/novel.db` 这两个混库**不会**被自动读取
  （见 `docs/使用指南.md` 第五节）；登记表为空时会自动搬进 Web 控制台槽位并改名 `*.legacy-bak`。
