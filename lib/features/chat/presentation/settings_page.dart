// lib/features/chat/presentation/settings_page.dart
// 设置页面 — 全量 DeepSeek API 参数可视化配置
//
// 页面结构（布局 v2）：
// - 浅灰底 + 白色圆角卡片，卡片只承担「内容块」，标题在卡外：
//   全页收敛成 7 个固定区块（必选鉴权 / 模型与联网搜索 / 生成参数 /
//   流式交互 / 去重与结构化 / 推理与调试 / 数据管理）；
// - 每行统一「左标签 + 右值」：值一律右对齐，下拉 = 值 + 小箭头、开关贴右，
//   所有右边缘都落在卡片 16dp 内边距这条线上；窄屏 / 大字号时长标签会自动
//   改成两行堆叠，保证 frequency_penalty 这类参数名不被省略号截断；
// - 除 API Key 这一处「焦点输入」外不再画灰底输入框：文本参数是一行无框、
//   右对齐的输入，聚焦时只出现一条 1px 主色下划线；
// - 数据管理是四条动作行（导出 / 导入 / 数据同步 / 检查更新），危险操作只用红色
//   图标 chip 提示，不用整块浅红/浅蓝的马卡龙按钮；
// - 条件行显隐时整张卡片用 AnimatedSize 做 180ms 平滑过渡。
//
// 视觉组件与令牌全部来自 core/widgets/settings_kit.dart（主设置页 v2 的
// 共用组件库），本文件只保留「页面结构 + 业务逻辑」，不再定义样式组件，
// 这样各功能页的设置界面能和这里共用同一套语言。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/config/app_version.dart';
import '../../../core/config/deepseek_models.dart';
import '../../../core/db/data_manager.dart';
import '../../../core/widgets/settings_kit.dart';
import '../../sync/presentation/sync_page.dart';
import '../../update/presentation/update_page.dart';
import '../application/chat_controller.dart'; // chatProvider
import '../application/setting_controller.dart';

/// SettingController Riverpod Provider
final settingProvider = ChangeNotifierProvider<SettingController>(
  (ref) => SettingController(),
);

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
/// 若干 `if (...) SettingsTextRow(...)` 条件项。条件项一增一减，后面所有
/// 子项的**位置**就整体平移，Flutter 会按位置把旧 State 复用到新位置上，
/// 于是 controller 里的内容跟着串位——实测「联网搜索」切成关闭后，
/// temperature 那一行显示出了百度 API Key 的值。
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
            backgroundColor: kSettingsPrimary,
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
        backgroundColor: err != null
            ? const Color(0xFFFF4D4F)
            : kSettingsPrimary,
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
        backgroundColor: err != null
            ? const Color(0xFFFF4D4F)
            : kSettingsPrimary,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _openSync() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const SyncPage()));
  }

  void _openUpdate() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const UpdatePage()));
  }

  @override
  Widget build(BuildContext context) {
    // 只订阅「决定页面结构」的三个值：是否加载完成、联网搜索来源、流式开关。
    //
    // 其余参数值不要 watch：文本 / 开关的值由各行自己的 StatefulWidget 持有
    // （initialValue 只在首次挂载时读一次）。若像以前那样 watch 整个控制器，
    // 每敲一个字符、每切一次开关都会把整页（600+ widget）重建一遍。
    final form = ref.watch(
      settingProvider.select(
        (c) => (
          isLoaded: c.isLoaded,
          engine: _normalizeEngine(c.searchEngine),
          stream: c.stream,
        ),
      ),
    );
    if (!form.isLoaded) {
      return const Scaffold(
        backgroundColor: kSettingsPageBg,
        body: Center(child: CircularProgressIndicator(color: kSettingsPrimary)),
      );
    }

    // 一次性读取当前值：只用来填各行的 initialValue，不建立依赖。
    final ctrl = ref.read(settingProvider);
    final engine = form.engine;

    return Scaffold(
      backgroundColor: kSettingsPageBg,
      appBar: SettingsAppBar(title: '设置', onSave: _onSave),
      body: ListView(
        // 顶部 2dp、左右 16dp 给卡片；底部留白用 ListView padding 实现，
        // 这样它能和安全区一起计算，不会出现"SizedBox 忘了算底部手势条"。
        padding: EdgeInsets.only(
          top: 2,
          left: kSettingsCardMarginH,
          right: kSettingsCardMarginH,
          bottom: 40 + MediaQuery.paddingOf(context).bottom,
        ),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        children: [
          // ── 1. 必选鉴权 ──
          const SettingsSectionHeader(
            icon: Icons.vpn_key_rounded,
            title: '必选鉴权',
            subtitle: '对话与官方联网搜索共用同一个 Key',
            isFirst: true,
          ),
          SettingsCard(
            children: [
              _ApiKeyCard(initialValue: ctrl.apiKey, onChanged: ctrl.setApiKey),
            ],
          ),

          // ── 2. 模型与联网搜索 ──
          const SettingsSectionHeader(
            icon: Icons.memory_rounded,
            title: '模型与联网搜索',
            subtitle: '选择对话模型与联网搜索行为',
          ),
          SettingsCard(
            children: [
              // 模型行内部还会按需渲染「自定义模型」行（同一张卡片）
              _ModelSelector(
                initialValue: ctrl.model,
                onChanged: ctrl.setModel,
              ),
              SettingsSelectRow(
                key: _k('search_engine'),
                label: '联网搜索',
                value: engine,
                options: const [
                  SettingsSelectOption(
                    'deepseek',
                    'DeepSeek 官方搜索',
                    shortLabel: 'DeepSeek 官方',
                  ),
                  SettingsSelectOption('baidu', '百度千帆搜索'),
                  SettingsSelectOption('off', '关闭'),
                ],
                onChanged: ctrl.setSearchEngine,
              ),
              // DeepSeek 官方搜索复用对话接口同一个 Key，不需要再配第三方 Key；
              // 百度仍需单独填 Key。
              if (engine == 'baidu')
                SettingsTextRow(
                  key: _k('baidu_api_key'),
                  label: '百度 API Key',
                  // 提示文案要在 1.15/1.3 倍字号下仍能整行放下，
                  // 否则空输入时会被省略号截断（真机 1.15 倍实测）。
                  hint: '百度千帆 Token',
                  initialValue: ctrl.baiduApiKey,
                  onChanged: ctrl.setBaiduApiKey,
                ),
              if (engine != 'off')
                SettingsTextRow(
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
                SettingsTextRow(
                  key: _k('search_freshness'),
                  label: '时间筛选',
                  hint: '留空不限',
                  initialValue: ctrl.searchFreshness,
                  onChanged: ctrl.setSearchFreshness,
                ),
              // 「抓取正文」只有 DeepSeek 官方搜索有这个开关（need_content）
              if (engine == 'deepseek')
                SettingsSwitchRow(
                  key: _k('search_need_content'),
                  label: '抓取网页正文',
                  subtitle: '抓取正文后回答更准，但更慢',
                  initialValue: ctrl.searchNeedContent,
                  onChanged: ctrl.setSearchNeedContent,
                ),
            ],
          ),

          // ── 3. 生成参数 ──
          const SettingsSectionHeader(
            icon: Icons.tune_rounded,
            title: '生成参数',
            subtitle: '影响回答的风格、长度与停止条件',
          ),
          SettingsCard(
            children: [
              SettingsTextRow(
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
              SettingsTextRow(
                key: _k('top_p'),
                label: 'top_p',
                hint: '0.0 ~ 1.0',
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                initialValue: ctrl.topP.toString(),
                onChanged: (v) => ctrl.setTopP(double.tryParse(v) ?? 1.0),
              ),
              SettingsTextRow(
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
              SettingsTextRow(
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
          const SettingsSectionHeader(
            icon: Icons.bolt_rounded,
            title: '流式交互',
            subtitle: '逐字返回，打字机效果',
          ),
          SettingsCard(
            children: [
              SettingsSwitchRow(
                key: _k('stream'),
                label: 'stream',
                subtitle: '逐字返回，打字机效果',
                initialValue: ctrl.stream,
                onChanged: ctrl.setStream,
              ),
              // stream_options 仅在流式开启时显示
              if (form.stream)
                SettingsTextRow(
                  key: _k('stream_options'),
                  label: 'stream_options',
                  hint: 'JSON 格式',
                  initialValue: ctrl.streamOptions,
                  onChanged: ctrl.setStreamOptions,
                ),
            ],
          ),

          // ── 5. 去重与结构化 ──
          const SettingsSectionHeader(
            icon: Icons.filter_alt_rounded,
            title: '去重与结构化',
            subtitle: '减少重复用词，约束输出格式',
          ),
          SettingsCard(
            children: [
              SettingsTextRow(
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
              SettingsTextRow(
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
              SettingsTextRow(
                key: _k('response_format'),
                label: 'response_format',
                hint: 'text / json_object',
                initialValue: ctrl.responseFormat,
                onChanged: ctrl.setResponseFormat,
              ),
            ],
          ),

          // ── 6. 推理与调试 ──
          const SettingsSectionHeader(
            icon: Icons.psychology_rounded,
            title: '推理与调试',
            subtitle: '推理过程、上下文轮数与调试参数',
          ),
          SettingsCard(
            children: [
              SettingsSwitchRow(
                key: _k('thinking'),
                label: 'thinking',
                subtitle: '返回推理过程，便于核对回答依据',
                initialValue: ctrl.thinking,
                onChanged: ctrl.setThinking,
              ),
              SettingsSwitchRow(
                key: _k('logprobs'),
                label: 'logprobs',
                subtitle: '返回每个 token 的对数概率',
                initialValue: ctrl.logprobs,
                onChanged: ctrl.setLogprobs,
              ),
              SettingsTextRow(
                key: _k('top_logprobs'),
                label: 'top_logprobs',
                hint: '0 ~ 20',
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                initialValue: ctrl.topLogprobs.toString(),
                onChanged: (v) => ctrl.setTopLogprobs(int.tryParse(v) ?? 0),
              ),
              SettingsTextRow(
                key: _k('logit_bias'),
                label: 'logit_bias',
                hint: 'JSON 格式',
                initialValue: ctrl.logitBias,
                onChanged: ctrl.setLogitBias,
              ),
              SettingsTextRow(
                key: _k('n'),
                label: 'n',
                hint: '生成数量',
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                initialValue: ctrl.n.toString(),
                onChanged: (v) => ctrl.setN(int.tryParse(v) ?? 1),
              ),
              SettingsTextRow(
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
          const SettingsSectionHeader(
            icon: Icons.storage_rounded,
            title: '数据管理',
            subtitle: '本地数据库备份、多端同步与 App 更新',
          ),
          SettingsCard(
            children: [
              SettingsActionRow(
                icon: Icons.upload_rounded,
                iconColor: kSettingsPrimary,
                softColor: kSettingsPrimarySoft,
                title: '导出数据库',
                subtitle: '备份到本地文件',
                onTap: _onExport,
              ),
              SettingsActionRow(
                icon: Icons.download_rounded,
                iconColor: kSettingsDanger,
                softColor: kSettingsDangerSoft,
                title: '导入数据库',
                titleColor: kSettingsDanger,
                subtitle: '从备份文件恢复，会覆盖现有数据',
                onTap: _onImport,
              ),
              SettingsActionRow(
                icon: Icons.sync_rounded,
                iconColor: kSettingsPrimary,
                softColor: kSettingsPrimarySoft,
                title: '数据同步',
                subtitle: '与电脑 Web 服务双向同步',
                onTap: _openSync,
              ),
              SettingsActionRow(
                icon: Icons.system_update_rounded,
                iconColor: kSettingsPrimary,
                softColor: kSettingsPrimarySoft,
                title: '检查更新',
                subtitle: '从电脑同步服务下载并安装新版本',
                onTap: _openUpdate,
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
                style: const TextStyle(
                  fontSize: 11,
                  color: kSettingsFooterText,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── 页面专属组件（不属于共用 kit） ───

/// API Key 区块：图标 + 标题 + 配置状态徽标 + 带描边的输入框。
///
/// 这是整页唯一的"填充式输入"，也是整页视觉焦点：浅灰底 + 12dp 圆角，
/// 聚焦时描边换成主色。其余参数全部无框，避免回到"灰框墙"。
/// （通用的「大段文本焦点卡」已抽到 kit 的 SettingsPromptCard；
/// 这里因为要支持 Key 掩码 / 眼睛开关 / 配置状态，保留为页面专属组件。）
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
      padding: const EdgeInsets.all(kSettingsCardPadH),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: kSettingsPrimarySoft,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.vpn_key_rounded,
                  size: 17,
                  color: kSettingsPrimary,
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
                    color: kSettingsTitle,
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
              color: kSettingsFieldBg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: _focused ? kSettingsPrimary : kSettingsFieldBorder,
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
                    cursorColor: kSettingsPrimary,
                    style: const TextStyle(
                      fontSize: 13.5,
                      color: kSettingsValue,
                    ),
                    onChanged: (v) {
                      // 首字符输入/清空时要刷新「已配置」徽标，所以这里 setState。
                      setState(() {});
                      widget.onChanged(v);
                    },
                    decoration: const InputDecoration(
                      hintText: '填入以 sk- 开头的 Key',
                      hintStyle: TextStyle(
                        fontSize: 12.5,
                        color: kSettingsHint,
                      ),
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
                    color: kSettingsSubtitle,
                  ),
                  tooltip: _obscured ? '显示 API Key' : '隐藏 API Key',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 34,
                    minHeight: 34,
                  ),
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
    final Color color = configured ? kSettingsSuccess : kSettingsSubtitle;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
      decoration: BoxDecoration(
        color: configured ? kSettingsSuccessSoft : kSettingsChipBg,
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
              color: configured ? kSettingsSuccess : kSettingsHint,
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
  static String _labelFor(String id) => DeepSeekModels.toDisplayName(id) ?? id;

  List<SettingsSelectOption> get _options => [
    for (final id in DeepSeekModels.selectableIds)
      SettingsSelectOption(id, _labelFor(id)),
    const SettingsSelectOption('custom', '自定义模型…'),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSelectRow(
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
          // （SettingsCard 只会在直接子项之间插线）。
          const Divider(
            height: 1,
            thickness: 1,
            color: kSettingsDivider,
            indent: kSettingsCardPadH,
            endIndent: kSettingsCardPadH,
          ),
          SettingsTextRow(
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
