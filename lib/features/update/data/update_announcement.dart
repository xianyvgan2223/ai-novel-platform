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
);

/// 历史更新公告（含当前版本），按版本从新到旧排列。
const List<UpdateAnnouncement> updateAnnouncementHistory = <UpdateAnnouncement>[
  currentUpdateAnnouncement,
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
