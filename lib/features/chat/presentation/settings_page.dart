// lib/features/chat/presentation/settings_page.dart
// 设置页面 — 全量 DeepSeek API 参数可视化配置
//
// 布局 v2（本轮重做）：
// - 页面浅灰底 + 白色圆角卡片，卡片只承担「内容块」，标题在卡外：
//   26dp 图标 chip + 14sp 标题 + 11.5sp 副标题，全页收敛成 7 个固定区块；
// - 每行统一「左标签 + 右值」：标签与值共享宽度（5 : 6），值一律右对齐；
//   下拉 = 值 + 小箭头、开关贴右，所有右边缘都落在卡片 16dp 内边距上；
//   320dp 窄屏或系统字号 > 1.15 时自动改为「标签一行、控件一行」的堆叠布局，
//   保证 frequency_penalty 这类长参数名不会被省略号截断；
//   360dp + 默认字号（真机常态）仍保持单行横向布局。
// - 除 API Key 这一处「焦点输入」外不再画灰底输入框：文本参数是一行无框、
//   右对齐的输入，聚焦时只出现一条 1px 主色下划线；
// - 数据管理改成三条动作行（导出 / 导入 / 数据同步），危险操作只用红色
//  图标 chip 提示，不再有整块浅红/浅蓝的马卡龙按钮；
// - 条件行显隐时整张卡片用 AnimatedSize 做 180ms 平滑过渡。
//
// 为什么去掉 v1 的固定 126dp 标签列：`n` / `stop` / `模型` 这类短标签后面
// 会空出 100dp+，而 `frequency_penalty` 又把列宽用满，标签列宽度与内容无关。
// 改成 Flexible(5) : Flexible(6) 后短标签自然收紧、长标签最多省略号，
// 右侧值共享同一条右边缘，整页只保留一套网格。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../application/setting_controller.dart';
import '../application/chat_controller.dart'; // chatProvider
import '../../../core/config/app_version.dart';
import '../../../core/config/deepseek_models.dart';
import '../../../core/db/data_manager.dart';
import '../../sync/presentation/sync_page.dart';

/// SettingController Riverpod Provider
final settingProvider = ChangeNotifierProvider<SettingController>(
  (ref) => SettingController(),
);

// ─── 视觉令牌：整页只从这里取色取尺寸，禁止行内出现新的魔法数字 ───

/// 全页唯一强调色（选中值 / 图标 chip / 保存按钮 / 聚焦线）。
const Color _kPrimary = Color(0xFF4D6BFE);

/// 图标 chip 的浅色底（分区标题、API Key、导出 / 同步动作行共用）。
const Color _kPrimarySoft = Color(0xFFEEF2FF);

const Color _kPageBg = Color(0xFFF4F5F7);
const Color _kCardBg = Color(0xFFFFFFFF);
const Color _kTitle = Color(0xFF14161A); // 分区标题 / 卡片标题
const Color _kLabel = Color(0xFF1F2329); // 行标签
const Color _kValue = Color(0xFF5A6474); // 右侧值
const Color _kSubtitle = Color(0xFF8A93A5); // 分区副标题 / 行说明
/// 输入提示文字：白卡上对比度约 3.08:1（#A0A8B6 只有 2.39:1，不达标）。
/// 与 _kSubtitle 同色，视觉上仍明显浅于右侧值文本。
const Color _kHint = Color(0xFF8A93A5);
const Color _kDivider = Color(0xFFF1F2F6);
const Color _kChevron = Color(0xFFC2C8D4);
const Color _kDanger = Color(0xFFF04A45);
const Color _kDangerSoft = Color(0xFFFEF1F0);
const Color _kSuccess = Color(0xFF2E9E55);
const Color _kSuccessSoft = Color(0xFFEAF7EF);

/// AppBar 底部分隔线与 API Key 输入框的静态描边，比行分隔线略深一点。
const Color _kAppBarDivider = Color(0xFFF0F1F4);
const Color _kFieldBorder = Color(0xFFEEF0F5);

/// 开关关闭态轨道色。
const Color _kSwitchInactive = Color(0xFFE3E6ED);

/// 页脚版本号颜色（整页最弱的一层信息）。
const Color _kFooterText = Color(0xFFB8BFCC);

// 几何
const double _kCardRadius = 16; // 卡片圆角
const double _kCardMarginH = 16; // 卡片左右外边距（= ListView 左右 padding）
const double _kCardPadH = 16; // 卡片内容左右内边距
const double _kRowMinHeight = 52; // 普通行（文本 / 下拉 / 开关）最小高度
const double _kRowPadV = 8; // 普通行上下内边距（有副标题的行自然变高）
const double _kSectionGapTop = 26; // 分区标题距上一张卡
const double _kSectionGapBot = 10; // 分区标题距本卡

/// 卡片投影：柔和、不带描边。offset 向下 2dp，避免卡片像「浮在页面上」。
const BoxShadow _kCardShadow = BoxShadow(
  color: Color(0x0F101828),
  blurRadius: 12,
  offset: Offset(0, 2),
);

// ─── 通用工具 ───

/// 行标签的字体样式：`_RowLabel` 渲染与 `_measureLabelWidth` 测量共用，
/// 保证"量出来的宽度"和"画出来的宽度"一定是同一套字号/字重/行高。
const TextStyle _kRowLabelStyle = TextStyle(
  fontSize: 13.5,
  fontWeight: FontWeight.w500,
  height: 1.25,
);

/// 用真实字体测量单行标签的自然宽度（含当前系统字号缩放）。
///
/// 为什么不按 textScale 阈值猜：真机系统 font_scale=1.15，恰好卡在
/// `> 1.15` 的判定边缘上，结果 360dp 下 frequency_penalty 被截成
/// `frequency_penal…`。这里用 TextPainter 实测：样式与真实渲染一致
/// （DefaultTextStyle 合并 + 当前 textScaler），任何字体、任何字号都不会截断。
double _measureLabelWidth(BuildContext context, String label) {
  final painter = TextPainter(
    text: TextSpan(
      text: label,
      // Text 渲染时会把自身 style 合并到 DefaultTextStyle 上，这里做同样的合并，
      // 才能拿到正确的字体族 / fontFamilyFallback（截图测试环境尤其重要）。
      style: DefaultTextStyle.of(context).style.merge(_kRowLabelStyle),
    ),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}

/// 是否把「左标签 + 右控件」改成两行堆叠。触发条件（任一）：
/// 1. 卡片内容宽 < 280dp（320dp 窄屏，横向两栏必然放不下）；
/// 2. 标签自然宽度超过横向布局里标签列能分到的宽度
///    （内容宽 - 12dp 间距后的 6/11，即文本行 flex 6:5 的标签列）。
///
/// 360dp + 1.15 倍系统字号下 frequency_penalty 实测约 131dp，
/// 小于 155dp 的标签列宽，因此仍保持横向布局，真机观感不变。
bool _useStackedRow(BuildContext context, double contentWidth, String label) {
  if (contentWidth < 280) return true;
  final labelSlot = (contentWidth - 12) * 6 / 11;
  return _measureLabelWidth(context, label) > labelSlot;
}

/// 归一化搜索来源取值：兼容历史数据。
///
/// 只认三个已知值，其余（列缺失导致的空串、脏数据）一律按「关闭」处理——
/// 搜索会花钱（DeepSeek 按次计费 / 百度要单独申请 Key），认不出来时宁可不开，
/// 也不能替用户打开。真正的"老库只有 web_search 布尔量"兼容在数据层做
/// （UserSetting._engineFromMap），那里能看到布尔量。
String _normalizeEngine(String raw) {
  const valid = <String>['baidu', 'deepseek', 'off'];
  return valid.contains(raw) ? raw : 'off';
}

/// 给每个设置项一个稳定且唯一的 Key。
///
/// 这些输入框用的是 StatefulWidget + 自建 TextEditingController，而列表里存在
/// 若干 `if (...) _TextRow(...)` 条件项。条件项一增一减，后面所有子项的
/// **位置**就整体平移，Flutter 会按位置把旧 State 复用到新位置上，于是
/// controller 里的内容跟着串位——实测「联网搜索」切成关闭后，temperature
/// 那一行显示出了百度 API Key 的值。
/// 加上按字段名生成的 Key 后，State 身份与字段绑定，不会再错位。
Key _k(String name) => ValueKey<String>('setting_$name');

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(settingProvider).loadSettings());
  }

  Future<void> _onSave() async {
    final settingCtrl = ref.read(settingProvider);
    try {
      await settingCtrl.saveSettings();
      // 清空对话控制器的配置缓存
      ref.read(chatProvider).clearSettingCache();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('设置已保存'),
            backgroundColor: _kPrimary,
            duration: Duration(seconds: 1),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('保存失败（数据库不可用）'),
            backgroundColor: Color(0xFFFF4D4F),
            duration: Duration(seconds: 1),
          ),
        );
      }
    }
  }

  Future<void> _onExport() async {
    final ctrl = ref.read(settingProvider);
    // 先保存当前设置，确保数据最新
    await ctrl.saveSettings();
    // 清空缓存，确保数据库连接释放
    ref.read(chatProvider).clearSettingCache();

    final err = await DataManager.exportDatabase();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(err ?? '数据库已导出'),
        backgroundColor: err != null ? const Color(0xFFFF4D4F) : _kPrimary,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _onImport() async {
    // 导入前先弹出确认
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入数据'),
        content: const Text('导入将覆盖当前所有数据（设置、会话、消息），确定继续吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定导入', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    final err = await DataManager.importDatabase();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(err ?? '数据导入成功，请重启应用生效'),
        backgroundColor: err != null ? const Color(0xFFFF4D4F) : _kPrimary,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _openSync() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const SyncPage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = ref.watch(settingProvider);
    if (!ctrl.isLoaded) {
      return const Scaffold(
        backgroundColor: _kPageBg,
        body: Center(
          child: CircularProgressIndicator(color: _kPrimary),
        ),
      );
    }

    final engine = _normalizeEngine(ctrl.searchEngine);

    return Scaffold(
      backgroundColor: _kPageBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, size: 22, color: _kTitle),
          tooltip: '返回',
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          '设置',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: _kTitle,
          ),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(child: _SaveButton(onPressed: _onSave)),
          ),
        ],
        // 1px 底部分隔线：白色 AppBar 与浅灰页面之间需要一条硬边界，
        // 但不要阴影（阴影会让头部看起来是悬浮的）。
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, thickness: 1, color: _kAppBarDivider),
        ),
      ),
      body: ListView(
        // 顶部 2dp、左右 16dp 给卡片；底部留白用 ListView padding 实现，
        // 这样它能和安全区一起计算，不会出现"SizedBox 忘了算底部手势条"。
        padding: EdgeInsets.only(
          top: 2,
          left: _kCardMarginH,
          right: _kCardMarginH,
          bottom: 40 + MediaQuery.paddingOf(context).bottom,
        ),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        children: [
          // ── 1. 必选鉴权 ──
          const _SectionHeader(
            icon: Icons.vpn_key_rounded,
            title: '必选鉴权',
            subtitle: '对话与官方联网搜索共用同一个 Key',
            isFirst: true,
          ),
          _SettingsCard(
            children: [
              _ApiKeyCard(
                initialValue: ctrl.apiKey,
                onChanged: ctrl.setApiKey,
              ),
            ],
          ),

          // ── 2. 模型与联网搜索 ──
          const _SectionHeader(
            icon: Icons.memory_rounded,
            title: '模型与联网搜索',
            subtitle: '选择对话模型与联网搜索行为',
          ),
          _SettingsCard(
            children: [
              // 模型行内部还会按需渲染「自定义模型」行（同一张卡片）
              _ModelSelector(
                initialValue: ctrl.model,
                onChanged: ctrl.setModel,
              ),
              _SelectRow(
                key: _k('search_engine'),
                label: '联网搜索',
                value: engine,
                options: const [
                  _SelectOption(
                    'deepseek',
                    'DeepSeek 官方搜索',
                    shortLabel: 'DeepSeek 官方',
                  ),
                  _SelectOption('baidu', '百度千帆搜索'),
                  _SelectOption('off', '关闭'),
                ],
                onChanged: ctrl.setSearchEngine,
              ),
              // DeepSeek 官方搜索复用对话接口同一个 Key，不需要再配第三方 Key；
              // 百度仍需单独填 Key。
              if (engine == 'baidu')
                _TextRow(
                  key: _k('baidu_api_key'),
                  label: '百度 API Key',
                  // 提示文案要在 1.15/1.3 倍字号下仍能整行放下，
                  // 否则空输入时会被省略号截断（真机 1.15 倍实测）。
                  hint: '百度千帆 Token',
                  initialValue: ctrl.baiduApiKey,
                  onChanged: ctrl.setBaiduApiKey,
                ),
              if (engine != 'off')
                _TextRow(
                  key: _k('search_count'),
                  label: '最大搜索条数',
                  hint: '默认 5，上限 20',
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  initialValue: ctrl.searchCount.toString(),
                  onChanged: (v) => ctrl.setSearchCount(int.tryParse(v) ?? 5),
                ),
              if (engine != 'off')
                _TextRow(
                  key: _k('search_freshness'),
                  label: '时间筛选',
                  hint: '留空不限',
                  initialValue: ctrl.searchFreshness,
                  onChanged: ctrl.setSearchFreshness,
                ),
              // 「抓取正文」只有 DeepSeek 官方搜索有这个开关（need_content）
              if (engine == 'deepseek')
                _SwitchRow(
                  key: _k('search_need_content'),
                  label: '抓取网页正文',
                  subtitle: '抓取正文后回答更准，但更慢',
                  initialValue: ctrl.searchNeedContent,
                  onChanged: ctrl.setSearchNeedContent,
                ),
            ],
          ),

          // ── 3. 生成参数 ──
          const _SectionHeader(
            icon: Icons.tune_rounded,
            title: '生成参数',
            subtitle: '影响回答的风格、长度与停止条件',
          ),
          _SettingsCard(
            children: [
              _TextRow(
                key: _k('temperature'),
                label: 'temperature',
                hint: '0.0 ~ 2.0',
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                initialValue: ctrl.temperature.toString(),
                onChanged: (v) =>
                    ctrl.setTemperature(double.tryParse(v) ?? 1.0),
              ),
              _TextRow(
                key: _k('top_p'),
                label: 'top_p',
                hint: '0.0 ~ 1.0',
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                initialValue: ctrl.topP.toString(),
                onChanged: (v) => ctrl.setTopP(double.tryParse(v) ?? 1.0),
              ),
              _TextRow(
                key: _k('max_tokens'),
                label: 'max_tokens',
                hint: '上限 384000',
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                initialValue: ctrl.maxTokens.toString(),
                onChanged: (v) => ctrl.setMaxTokens(int.tryParse(v) ?? 4096),
                formatter: (v) {
                  final parsed = int.tryParse(v);
                  if (parsed == null) return v;
                  return parsed.clamp(1, 384000).toString();
                },
              ),
              _TextRow(
                key: _k('stop'),
                label: 'stop',
                // 提示文案要在 1.3 倍字号下仍能整行放下（原「停止词，逗号分隔」
                // 在 1.3 倍时超出值区域会被省略号截断）。
                hint: '多个用逗号分隔',
                initialValue: ctrl.stop,
                onChanged: ctrl.setStop,
              ),
            ],
          ),

          // ── 4. 流式交互 ──
          const _SectionHeader(
            icon: Icons.bolt_rounded,
            title: '流式交互',
            subtitle: '逐字返回，打字机效果',
          ),
          _SettingsCard(
            children: [
              _SwitchRow(
                key: _k('stream'),
                label: 'stream',
                subtitle: '逐字返回，打字机效果',
                initialValue: ctrl.stream,
                onChanged: ctrl.setStream,
              ),
              // stream_options 仅在流式开启时显示
              if (ctrl.stream)
                _TextRow(
                  key: _k('stream_options'),
                  label: 'stream_options',
                  hint: 'JSON 格式',
                  initialValue: ctrl.streamOptions,
                  onChanged: ctrl.setStreamOptions,
                ),
            ],
          ),

          // ── 5. 去重与结构化 ──
          const _SectionHeader(
            icon: Icons.filter_alt_rounded,
            title: '去重与结构化',
            subtitle: '减少重复用词，约束输出格式',
          ),
          _SettingsCard(
            children: [
              _TextRow(
                key: _k('frequency_penalty'),
                label: 'frequency_penalty',
                hint: '-2.0 ~ 2.0',
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                initialValue: ctrl.frequencyPenalty.toString(),
                onChanged: (v) =>
                    ctrl.setFrequencyPenalty(double.tryParse(v) ?? 0.0),
              ),
              _TextRow(
                key: _k('presence_penalty'),
                label: 'presence_penalty',
                hint: '-2.0 ~ 2.0',
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                initialValue: ctrl.presencePenalty.toString(),
                onChanged: (v) =>
                    ctrl.setPresencePenalty(double.tryParse(v) ?? 0.0),
              ),
              _TextRow(
                key: _k('response_format'),
                label: 'response_format',
                hint: 'text / json_object',
                initialValue: ctrl.responseFormat,
                onChanged: ctrl.setResponseFormat,
              ),
            ],
          ),

          // ── 6. 推理与调试 ──
          const _SectionHeader(
            icon: Icons.psychology_rounded,
            title: '推理与调试',
            subtitle: '推理过程、上下文轮数与调试参数',
          ),
          _SettingsCard(
            children: [
              _SwitchRow(
                key: _k('thinking'),
                label: 'thinking',
                subtitle: '返回推理过程，便于核对回答依据',
                initialValue: ctrl.thinking,
                onChanged: ctrl.setThinking,
              ),
              _SwitchRow(
                key: _k('logprobs'),
                label: 'logprobs',
                subtitle: '返回每个 token 的对数概率',
                initialValue: ctrl.logprobs,
                onChanged: ctrl.setLogprobs,
              ),
              _TextRow(
                key: _k('top_logprobs'),
                label: 'top_logprobs',
                hint: '0 ~ 20',
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                initialValue: ctrl.topLogprobs.toString(),
                onChanged: (v) => ctrl.setTopLogprobs(int.tryParse(v) ?? 0),
              ),
              _TextRow(
                key: _k('logit_bias'),
                label: 'logit_bias',
                hint: 'JSON 格式',
                initialValue: ctrl.logitBias,
                onChanged: ctrl.setLogitBias,
              ),
              _TextRow(
                key: _k('n'),
                label: 'n',
                hint: '生成数量',
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                initialValue: ctrl.n.toString(),
                onChanged: (v) => ctrl.setN(int.tryParse(v) ?? 1),
              ),
              _TextRow(
                key: _k('context_rounds'),
                label: '上下文轮数',
                // 默认值 10 作为当前值已经显示在右侧，提示只留取值范围，
                // 保证 1.15/1.3 倍字号下整行放得下、不出现省略号。
                hint: '1 ~ 100',
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                initialValue: ctrl.contextRounds.toString(),
                onChanged: (v) => ctrl.setContextRounds(
                  SettingController.clampContextRounds(int.tryParse(v) ?? 10),
                ),
              ),
            ],
          ),

          // ── 7. 数据管理 ──
          const _SectionHeader(
            icon: Icons.storage_rounded,
            title: '数据管理',
            subtitle: '本地数据库备份与多端同步',
          ),
          _SettingsCard(
            children: [
              _ActionRow(
                icon: Icons.upload_rounded,
                iconColor: _kPrimary,
                softColor: _kPrimarySoft,
                title: '导出数据库',
                subtitle: '备份到本地文件',
                onTap: _onExport,
              ),
              _ActionRow(
                icon: Icons.download_rounded,
                iconColor: _kDanger,
                softColor: _kDangerSoft,
                title: '导入数据库',
                titleColor: _kDanger,
                subtitle: '从备份文件恢复，会覆盖现有数据',
                onTap: _onImport,
              ),
              _ActionRow(
                icon: Icons.sync_rounded,
                iconColor: _kPrimary,
                softColor: _kPrimarySoft,
                title: '数据同步',
                subtitle: '与电脑 Web 服务双向同步',
                onTap: _openSync,
              ),
            ],
          ),

          // 当前版本号：放在整页最下方（数据管理之后），用户反馈问题时能直接报版本。
          // 版本号来源见 core/config/app_version.dart（与 pubspec.yaml 由单测保证同步）。
          Padding(
            padding: const EdgeInsets.only(top: 28),
            child: Center(
              child: Text(
                '当前版本 v$kAppVersion',
                style: const TextStyle(fontSize: 11, color: _kFooterText),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── 页面骨架组件 ───

/// 分区标题：26dp 图标 chip + 标题 +（可选）副标题。
///
/// 标题放在卡片外面而不是卡片里：卡片负责「内容块」，标题负责「导航」。
/// 7 个区块全部带副标题，这样每个标题块高度一致，滚动时节拍是均匀的。
class _SectionHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;

  /// 是否是页面第一组：首组上方不需要再留 26dp，让首屏多露一点内容。
  final bool isFirst;

  const _SectionHeader({
    required this.icon,
    required this.title,
    this.subtitle,
    this.isFirst = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        4,
        isFirst ? 14 : _kSectionGapTop,
        4,
        _kSectionGapBot,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: _kPrimarySoft,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 15, color: _kPrimary),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: _kTitle,
                    height: 1.25,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: _kSubtitle,
                      height: 1.25,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 白色圆角卡片：白底 + 柔和投影（不描边），直接子项之间自动插 1px 分隔线。
///
/// 用 AnimatedSize 包住内容列，让条件行（百度 Key / stream_options 等）
/// 显示或隐藏时卡片高度平滑变化，而不是"跳一下"。
/// 内层 Material 只负责给 InkWell 提供水波纹载体（transparent 不遮挡白底）。
class _SettingsCard extends StatelessWidget {
  final List<Widget> children;
  const _SettingsCard({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: _kCardBg,
        borderRadius: BorderRadius.circular(_kCardRadius),
        boxShadow: const [_kCardShadow],
      ),
      child: Material(
        type: MaterialType.transparency,
        child: AnimatedSize(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          alignment: Alignment.topCenter,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0)
                  const Divider(
                    height: 1,
                    thickness: 1,
                    color: _kDivider,
                    indent: _kCardPadH,
                    endIndent: _kCardPadH,
                  ),
                children[i],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 「左标签 + 右值」共用的标签部分。
///
/// 标签与值共享宽度、最多一行，长了就省略号——不再给固定标签列，
/// 短标签不会在后面留一个巨洞。点标签区域也能聚焦右侧输入框。
class _RowLabel extends StatelessWidget {
  final String label;
  final String? subtitle;
  final VoidCallback? onTap;

  const _RowLabel(this.label, {this.subtitle, this.onTap});

  @override
  Widget build(BuildContext context) {
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          // 与 _measureLabelWidth 共用同一份字体样式，测量/渲染不会漂移。
          style: _kRowLabelStyle.copyWith(color: _kLabel),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 2),
          Text(
            subtitle!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 11,
              color: _kSubtitle,
              height: 1.25,
            ),
          ),
        ],
      ],
    );
    if (onTap == null) return content;
    // 输入框没有四边框，只靠右侧一段文字不容易点中；标签区一起聚焦。
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: content,
    );
  }
}

// ─── 行类型 ───

/// A. 文本 / 数字参数行：无框、右对齐输入，聚焦时才出现一条主色下划线。
///
/// 这是本页唯一的"裸输入"：不再给每个参数包一个浅灰填充框，
/// 整页的灰框墙由此消失（唯一保留的填充输入是 API Key 焦点卡）。
class _TextRow extends StatefulWidget {
  final String label;
  final String hint;
  final String initialValue;
  final ValueChanged<String> onChanged;

  /// 输入格式化器：用户输入后调用，返回与显示同步的值（如裁剪数字范围）
  final String? Function(String input)? formatter;

  /// 数值参数用数字键盘，文本 / JSON 参数用默认文本键盘。
  final TextInputType keyboardType;

  const _TextRow({
    super.key,
    required this.label,
    required this.hint,
    required this.initialValue,
    required this.onChanged,
    this.formatter,
    this.keyboardType = TextInputType.text,
  });

  @override
  State<_TextRow> createState() => _TextRowState();
}

class _TextRowState extends State<_TextRow> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
    _focusNode = FocusNode();
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    widget.onChanged(v);
    final formatted = widget.formatter?.call(v);
    if (formatted != null && formatted != v && _controller.text == v) {
      _controller.text = formatted;

      // 将光标移到末尾
      _controller.selection = TextSelection.fromPosition(
        TextPosition(offset: formatted.length),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final stacked = _useStackedRow(
          context,
          constraints.maxWidth - 2 * _kCardPadH,
          widget.label,
        );
        final label = _RowLabel(
          widget.label,
          onTap: () => _focusNode.requestFocus(),
        );
        final field = TextField(
          controller: _controller,
          focusNode: _focusNode,
          onChanged: _onChanged,
          textAlign: TextAlign.right,
          textInputAction: TextInputAction.done,
          keyboardType: widget.keyboardType,
          cursorColor: _kPrimary,
          style: const TextStyle(fontSize: 13.5, color: _kValue),
          decoration: InputDecoration(
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(vertical: 6),
            hintText: widget.hint,
            hintStyle: const TextStyle(fontSize: 12.5, color: _kHint),
            // 平时完全透明，聚焦时只有底部一条主色线：
            // 输入框与只读值在视觉上是同一种文字，不再是两套控件。
            border: const UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.transparent, width: 1),
            ),
            enabledBorder: const UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.transparent, width: 1),
            ),
            focusedBorder: const UnderlineInputBorder(
              borderSide: BorderSide(color: _kPrimary, width: 1),
            ),
          ),
        );
        return ConstrainedBox(
          constraints: const BoxConstraints(minHeight: _kRowMinHeight),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: _kCardPadH,
              // 堆叠时标签和输入框分两行，上下留白要跟着多一点
              vertical: stacked ? 10 : _kRowPadV,
            ),
            child: stacked
                // 窄屏 / 大字号：标签独占一行，输入框整行宽、内容仍右对齐。
                // 这样 frequency_penalty 这类长参数名永远不会被省略号截断。
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      label,
                      const SizedBox(height: 2),
                      field,
                    ],
                  )
                : Row(
                    children: [
                      // 左右都用 Expanded（Flexible 的紧约束版）：Flexible 的松约束下，
                      // 标签只占自然宽度、剩余空间会堆在行尾，值就跟着"贴不齐最右边"。
                      // Expanded 强制标签占满 6/11、值占满 5/11，右侧值的右边缘
                      // 才永远落在卡片 16dp 内边距这条线上。
                      // 标签给 6/11 而不是 5/11：真机 font_scale=1.15 时
                      // frequency_penalty 实测约 131dp，5/11（129dp）正好放不下。
                      Expanded(flex: 6, child: label),
                      const SizedBox(width: 12),
                      Expanded(flex: 5, child: field),
                    ],
                  ),
          ),
        );
      },
    );
  }
}

/// B. 下拉行：整行可点，右侧是「当前值 + 小箭头」；点开是带勾的菜单。
///
/// 不用 DropdownButton 的原因：它的按钮高度跟随文字，想要整行热区得自己
/// 套 InkWell；PopupMenuButton 可以直接把整行当 child，热区天然对齐。
class _SelectRow extends StatelessWidget {
  final String label;
  final String value;
  final List<_SelectOption> options;
  final ValueChanged<String> onChanged;

  const _SelectRow({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final current = options.firstWhere(
      (o) => o.value == value,
      orElse: () => options.first,
    );
    return PopupMenuButton<String>(
      tooltip: '',
      padding: EdgeInsets.zero,
      position: PopupMenuPosition.under,
      offset: const Offset(0, 4),
      color: Colors.white,
      elevation: 6,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      onSelected: onChanged,
      itemBuilder: (context) => [
        for (final option in options)
          PopupMenuItem<String>(
            value: option.value,
            height: 44,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    option.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13.5,
                      color: option.value == value ? _kPrimary : _kLabel,
                      fontWeight: option.value == value
                          ? FontWeight.w500
                          : FontWeight.w400,
                    ),
                  ),
                ),
                if (option.value == value)
                  const Icon(Icons.check_rounded, size: 16, color: _kPrimary),
              ],
            ),
          ),
      ],
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 下拉行保持 5:6；标签都很短，只有 320dp 窄屏才会触发堆叠。
          final stacked = _useStackedRow(
            context,
            constraints.maxWidth - 2 * _kCardPadH,
            label,
          );
          final labelText = Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: _kRowLabelStyle.copyWith(color: _kLabel),
          );
          // 「当前值 + 小箭头」：箭头永远贴最右，值右对齐在箭头左侧。
          final valueRow = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  current.displayLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontSize: 13.5, color: _kValue),
                ),
              ),
              const SizedBox(width: 2),
              const Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 18,
                color: _kChevron,
              ),
            ],
          );
          return ConstrainedBox(
            constraints: const BoxConstraints(minHeight: _kRowMinHeight),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: _kCardPadH,
                // 堆叠时标签和值分两行，上下留白要跟着多一点
                vertical: stacked ? 10 : _kRowPadV,
              ),
              child: stacked
                  // 窄屏 / 大字号：标签独占一行，值 + 箭头右对齐放下一行。
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        labelText,
                        const SizedBox(height: 2),
                        Align(
                          alignment: Alignment.centerRight,
                          child: valueRow,
                        ),
                      ],
                    )
                  : Row(
                      children: [
                        // 与 _TextRow 同理：Expanded 才能把行尾剩余空间吃掉，
                        // 让下拉箭头（= 值的右边缘）压在同一条 16dp 线上。
                        // 下拉标签都很短，保持 5:6 给值留更宽的位置。
                        Expanded(flex: 5, child: labelText),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 6,
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: valueRow,
                          ),
                        ),
                      ],
                    ),
            ),
          );
        },
      ),
    );
  }
}

/// C. 开关行：整行可点，开关贴卡片最右，视觉右边缘与文本值对齐。
///
/// Flutter M3 Switch 的布局是 52×40（52 宽轨道 + 40dp 最小点击区），
/// 比一行文字高 8dp。这里用 SizedBox(height: 32) 把布局高度压到文字行以内，
/// 行高才不会从 52 被撑到 60。
/// 宽度方向：Switch 左右各带 4dp 内边距（默认 padding），去掉后 52dp 的轨道
/// 正好填满 52dp 的布局盒；再做 0.9 缩放并以 centerRight 为锚点，
/// 缩放后的轨道右边缘仍然压在卡片 16dp 内边距线上。
class _SwitchRow extends StatefulWidget {
  final String label;
  final String? subtitle;
  final bool initialValue;
  final ValueChanged<bool> onChanged;

  const _SwitchRow({
    super.key,
    required this.label,
    required this.initialValue,
    required this.onChanged,
    this.subtitle,
  });

  @override
  State<_SwitchRow> createState() => _SwitchRowState();
}

class _SwitchRowState extends State<_SwitchRow> {
  late bool _value;

  @override
  void initState() {
    super.initState();
    _value = widget.initialValue;
  }

  void _toggle() {
    setState(() => _value = !_value);
    widget.onChanged(_value);
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: _toggle,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: _kRowMinHeight),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(_kCardPadH, 10, _kCardPadH, 10),
          child: Row(
            children: [
              Expanded(
                child: _RowLabel(widget.label, subtitle: widget.subtitle),
              ),
              const SizedBox(width: 12),
              SizedBox(
                height: 32,
                child: Transform.scale(
                  scale: 0.9,
                  alignment: Alignment.centerRight,
                  child: Switch(
                    value: _value,
                    onChanged: (_) => _toggle(),
                    padding: EdgeInsets.zero,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    activeTrackColor: _kPrimary,
                    activeThumbColor: Colors.white,
                    inactiveTrackColor: _kSwitchInactive,
                    inactiveThumbColor: Colors.white,
                    // M3 默认的开关描边在浅色卡片上显得很"重"，去掉后更干净。
                    trackOutlineColor:
                        const WidgetStatePropertyAll<Color?>(
                      Colors.transparent,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// D. 动作行：图标 chip + 标题 + 说明 + 右箭头（导出 / 导入 / 数据同步）。
class _ActionRow extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final Color softColor;
  final String title;
  final String subtitle;

  /// 危险动作用红色标题（导入会覆盖数据）。
  final Color? titleColor;
  final VoidCallback onTap;

  const _ActionRow({
    required this.icon,
    required this.iconColor,
    required this.softColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.titleColor,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(_kCardPadH, 12, _kCardPadH, 12),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: softColor,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, size: 18, color: iconColor),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w500,
                        color: titleColor ?? _kLabel,
                        height: 1.25,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: _kSubtitle,
                        height: 1.25,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: _kChevron,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── API Key 焦点卡（全页唯一的填充式输入） ───

/// API Key 区块：图标 + 标题 + 配置状态徽标 + 带描边的输入框。
///
/// 这是整页唯一的"填充式输入"，也是整页视觉焦点：浅灰底 + 12dp 圆角，
/// 聚焦时描边换成主色。其余参数全部无框，避免回到"灰框墙"。
class _ApiKeyCard extends StatefulWidget {
  final String initialValue;
  final ValueChanged<String> onChanged;

  const _ApiKeyCard({required this.initialValue, required this.onChanged});

  @override
  State<_ApiKeyCard> createState() => _ApiKeyCardState();
}

class _ApiKeyCardState extends State<_ApiKeyCard> {
  bool _obscured = true;
  bool _focused = false;
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
    _focusNode = FocusNode()..addListener(_handleFocusChange);
  }

  void _handleFocusChange() {
    if (_focused != _focusNode.hasFocus) {
      setState(() => _focused = _focusNode.hasFocus);
    }
  }

  @override
  void dispose() {
    _focusNode
      ..removeListener(_handleFocusChange)
      ..dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final configured = _controller.text.trim().isNotEmpty;
    return Padding(
      padding: const EdgeInsets.all(_kCardPadH),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: _kPrimarySoft,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.vpn_key_rounded,
                  size: 17,
                  color: _kPrimary,
                ),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'DeepSeek API Key',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: _kTitle,
                  ),
                ),
              ),
              _KeyStatusChip(configured: configured),
            ],
          ),
          const SizedBox(height: 12),
          AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            height: 46,
            padding: const EdgeInsets.fromLTRB(12, 0, 4, 0),
            decoration: BoxDecoration(
              color: const Color(0xFFF7F8FA),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: _focused ? _kPrimary : _kFieldBorder,
                width: _focused ? 1.2 : 1,
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    focusNode: _focusNode,
                    obscureText: _obscured,
                    autocorrect: false,
                    enableSuggestions: false,
                    textInputAction: TextInputAction.done,
                    cursorColor: _kPrimary,
                    style: const TextStyle(fontSize: 13.5, color: _kValue),
                    onChanged: (v) {
                      // 首字符输入/清空时要刷新「已配置」徽标，所以这里 setState。
                      setState(() {});
                      widget.onChanged(v);
                    },
                    decoration: const InputDecoration(
                      hintText: '填入以 sk- 开头的 Key',
                      hintStyle: TextStyle(fontSize: 12.5, color: _kHint),
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => setState(() => _obscured = !_obscured),
                  icon: Icon(
                    _obscured
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    size: 18,
                    color: _kSubtitle,
                  ),
                  tooltip: _obscured ? '显示 API Key' : '隐藏 API Key',
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 34, minHeight: 34),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// API Key 是否已填写的小徽标。
class _KeyStatusChip extends StatelessWidget {
  final bool configured;
  const _KeyStatusChip({required this.configured});

  @override
  Widget build(BuildContext context) {
    final Color color = configured ? _kSuccess : _kSubtitle;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
      decoration: BoxDecoration(
        color: configured ? _kSuccessSoft : const Color(0xFFF1F3F7),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: configured ? _kSuccess : _kHint,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            configured ? '已配置' : '未配置',
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w500,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── 下拉选项 / 模型选择器 / 保存按钮 ───

/// 下拉框的一个选项。
///
/// [label] 是菜单里的完整文案，[shortLabel] 是收起状态显示在行尾的
/// 短文案——「DeepSeek 官方搜索」在窄屏上会被截成「DeepSeek 官…」，
/// 所以收起态只显示「DeepSeek 官方」。
class _SelectOption {
  final String value;
  final String label;
  final String? shortLabel;
  const _SelectOption(this.value, this.label, {this.shortLabel});

  String get displayLabel => shortLabel ?? label;
}

/// 模型选择器：官方模型下拉 +（选中"自定义"时）紧跟一行自定义输入。
class _ModelSelector extends StatefulWidget {
  final String initialValue;
  final ValueChanged<String> onChanged;
  const _ModelSelector({required this.initialValue, required this.onChanged});

  @override
  State<_ModelSelector> createState() => _ModelSelectorState();
}

class _ModelSelectorState extends State<_ModelSelector> {
  late String _value;
  bool _isCustom = false;
  late final TextEditingController _customCtrl;

  @override
  void initState() {
    super.initState();
    // 兼容历史值：deepseek-v4-flash 会先被归一成 deepseek-flash，
    // 因此老用户打开设置页时看到的也是「flash」而不是掉进"自定义"。
    _value = DeepSeekModels.toApiId(widget.initialValue);
    _isCustom = !DeepSeekModels.isOfficial(_value);
    _customCtrl = TextEditingController(text: _isCustom ? _value : '');
  }

  @override
  void dispose() {
    _customCtrl.dispose();
    super.dispose();
  }

  /// 下拉项文案：只显示简称（flash / pro）。
  /// 真实 API 标识由选项的 value 承载，不占界面位置。
  static String _labelFor(String id) =>
      DeepSeekModels.toDisplayName(id) ?? id;

  List<_SelectOption> get _options => [
        for (final id in DeepSeekModels.selectableIds)
          _SelectOption(id, _labelFor(id)),
        const _SelectOption('custom', '自定义模型…'),
      ];

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SelectRow(
          label: '模型',
          value: _isCustom ? 'custom' : _value,
          options: _options,
          onChanged: (v) {
            if (v == 'custom') {
              setState(() => _isCustom = true);
              widget.onChanged(_customCtrl.text);
            } else {
              setState(() {
                _isCustom = false;
                _value = v;
              });
              widget.onChanged(v);
            }
          },
        ),
        if (_isCustom) ...[
          // 自定义输入属于同一张卡片里的下一行，手动补一条分隔线
          // （卡片只会在 _SettingsCard 的直接子项之间插线）。
          const Divider(
            height: 1,
            thickness: 1,
            color: _kDivider,
            indent: _kCardPadH,
            endIndent: _kCardPadH,
          ),
          _TextRow(
            key: _k('custom_model'),
            label: '自定义模型',
            hint: '输入模型标识',
            initialValue: _customCtrl.text,
            onChanged: (v) => widget.onChanged(v),
          ),
        ],
      ],
    );
  }
}

/// 保存按钮：AppBar 右侧的主色胶囊按钮。
///
/// 字号 / 字重放在 Text 上而不是 TextButton.styleFrom 的 textStyle 里：
/// 后者会整体替换按钮默认的 labelLarge 样式（连字体族一起丢掉），
/// 在不同字体环境下「保存」两个字容易渲染成豆腐块。
class _SaveButton extends StatelessWidget {
  final VoidCallback onPressed;
  const _SaveButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 34,
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          backgroundColor: _kPrimary,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          minimumSize: const Size(0, 34),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: const StadiumBorder(),
        ),
        child: const Text(
          '保存',
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}
