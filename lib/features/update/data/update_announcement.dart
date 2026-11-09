/// lib/features/update/data/update_announcement.dart
/// 更新公告文案：当前版本 + 历史版本。
///
/// 当前公告只在「首次打开新版本」时展示一次；releaseId 必须与
/// `kAppReleaseId`（lib/core/config/app_version.dart）保持一致。
/// 历史公告供「设置 → 数据管理 → 更新日志」回看，新版本加在最前面。
class UpdateAnnouncement {
  final String releaseId;
  final String version;

  /// 发布日期（yyyy-MM-dd），只用于更新日志展示。
  final String date;
  final String title;
  final String subtitle;
  final List<String> items;

  const UpdateAnnouncement({
    required this.releaseId,
    required this.version,
    this.date = '',
    required this.title,
    required this.subtitle,
    required this.items,
  });
}

const UpdateAnnouncement currentUpdateAnnouncement = UpdateAnnouncement(
  releaseId: '5.3.3+15',
  version: '5.3.3',
  date: '2026-11-07',
  title: '这次更新',
  subtitle: '导出大纲自动重排编号，AI 生成只做短线伏笔。',
  items: <String>[
    '导出大纲 txt 前会自动把事件 / 幕标题统一成规范写法并重新编号（大事件全篇连续、小事件在大事件内从 1 开始）；数据库原文不动，导入仍能正确识别。',
    '一键生成大纲：伏笔只做短线（5 个大事件内回收），不再要求预留长线伏笔；已回收 / 已实现的伏笔不再注入后续生成，跨 5 个大事件未回收的自动从账本去掉。',
    '小事件详写（写正文与 AI 审校）：已回收 / 已实现的伏笔不再注入提示词。',
    '大纲编辑 AI 生成提示词优化：概要写成连贯叙述、不要逐条列；场景描写 / 对白 / 心理刻画只在概要本来就有这类内容时出现。',
    '联网搜索注入的当前时间改为只带时间本身，不再附加行为指令。',
    '匹配大纲格式、批量拆分小事件的字数限制已去除；网页版相关 AI 提示词与手机端同步。',
  ],
);

/// 历史更新公告（含当前版本），按版本从新到旧排列。
const List<UpdateAnnouncement> updateAnnouncementHistory = <UpdateAnnouncement>[
  currentUpdateAnnouncement,
  UpdateAnnouncement(
    releaseId: '5.3.2+14',
    version: '5.3.2',
    date: '2026-11-06',
    title: '这次更新',
    subtitle: '聊天回复自动去掉 Markdown 符号，联网搜索时带上当前时间。',
    items: <String>[
      '聊天回复改为展示层自动清洗 Markdown：标题、加粗、列表、代码块等标记不再以 **、##、``` 的形式出现，直接显示干净文本（复制出去的也是清洗后的）。',
      '开启联网搜索后，聊天会自动带上当前日期与时间（精确到分钟、含星期），问「今天 / 最新」更准确。',
      '历史会话抽屉宽度从屏幕 80% 调整为 85%，长标题有更多显示空间。',
      '写小说：导出 / 导入大纲 txt 升级为 v2，会带上类型、主题、主角简介、世界观、伏笔清单与人物档案；导入时一并还原。',
      '大纲编辑：选择事件页默认不显示复选框，长按进入多选；顶栏「设定」可编辑书名 / 类型 / 主题 / 主角简介 / 世界观。',
      '大纲编辑：编辑页与选择事件页都加了常显可拖动滚动条；卡片右上角横排「⋯」菜单收纳添加 / 删除 / AI 生成。',
      '「大纲编辑」选作品页支持长按删除整部大纲。',
    ],
  ),
  UpdateAnnouncement(
    releaseId: '5.3.1+13',
    version: '5.3.1',
    date: '2026-11-04',
    title: '这次更新',
    subtitle: '聊天主页滚动条只在滑动时显示。',
    items: <String>[
      '聊天主页优化：消息列表的滚动条改为只在滑动过程中出现，停止滚动后自动淡出，平时不再一直压在消息右侧。',
      '内容不足一屏（不需要滚动）时不会出现滚动条，界面更干净。',
    ],
  ),
  UpdateAnnouncement(
    releaseId: '5.3.0+12',
    version: '5.3.0',
    date: '2026-11-04',
    title: '这次更新',
    subtitle: '写小说支持一键导出 / 导入大纲 txt。',
    items: <String>[
      '「写小说」页新增导出大纲 txt：选一部作品，一键把大纲正文存成 txt 文件（UTF-8，Windows 记事本可直接打开）。',
      '新增导入大纲 txt：自动识别 UTF-8 / UTF-16 编码并推导书名，导入后自动解析大事件与小事件，可直接去「大纲编辑」继续改。',
      '导出 / 导入入口直接接在写小说功能列表末尾；提示字号缩小，切换页面时提示会自动收起，不再残留到其他页面。',
      '网页版「写作」页同步支持导出下载与上传导入，手机和电脑之间对导大纲更方便。',
    ],
  ),
  UpdateAnnouncement(
    releaseId: '5.2.5+11',
    version: '5.2.5',
    date: '2026-10-29',
    title: '这次更新',
    subtitle: '网页写作对齐手机端，术语统一为小事件。',
    items: <String>[
      '网页写作新增 AI 设置：大纲、章节、战斗三套参数与提示词，和手机端读写同一份设置。',
      '大纲编辑支持多选事件/小事件逐项修改；AI 改写先在对应项下方给出结果，确认后再替换，并支持撤回。',
      '大纲编辑新增 AI 多轮对话：可围绕当前事件边聊边改，也可把同批所选事件一起交给 AI。',
      '网页补齐「听大纲改名」「AI 写战斗」「匹配大纲格式」三个功能。',
      '网页生成的大纲改为手机端可解析格式；已有旧格式作品可在大纲正文里一键转为手机格式。',
      '「大纲转章节」更名为「小事件详写」，相关界面与提示词统一使用小事件。',
      '悬浮聊天球恢复为蓝色圆形 + 白色图标。',
    ],
  ),
  UpdateAnnouncement(
    releaseId: '5.2.4+10',
    version: '5.2.4',
    date: '2026-10-29',
    title: '这次更新',
    subtitle: '整库同步更可靠，写作功能搬到电脑上。',
    items: <String>[
      '整库同步：电脑点「同步手机」后，手机会弹窗让你确认，同意后才执行；拒绝也会明确回报。',
      '修复大作品同步失败：作品数据超过 2MB 时不再被整表跳过，章节不会再报「父记录不存在」。',
      '同步报告会显示失败条数，问题不再被静默吞掉。',
      '网页新增「写作优化」：可把手机里的作品/章节导入电脑继续写，并支持 AI 润色、续写与抽卡。',
    ],
  ),
  UpdateAnnouncement(
    releaseId: '5.2.2+7',
    version: '5.2.2',
    date: '2026-10-28',
    title: '这次更新',
    subtitle: '几处细节调整，让设置和更新更顺手。',
    items: <String>[
      '设置里的「夜间模式」已更名为「主题」，继续支持跟随系统、浅色、深色。',
      '更新公告改为更紧凑的卡片样式，去掉多余图标，阅读更清爽。',
      '应用更新成功后会自动清理旧 APK；更新下载超时放宽到 30 分钟。',
    ],
  ),
  UpdateAnnouncement(
    releaseId: '5.2.1+6',
    version: '5.2.1',
    date: '2026-10-27',
    title: '这次更新',
    subtitle: '更新后自动清理旧安装包，并加入更新公告。',
    items: <String>[
      '应用更新成功后，下次启动自动删除已经安装过的旧 APK。',
      '首次打开新版本会显示更新公告，同一版本只显示一次。',
    ],
  ),
];
