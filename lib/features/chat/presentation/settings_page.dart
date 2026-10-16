/// lib/views/settings_page.dart
/// 设置页面 — 全量 DeepSeek API 参数可视化配置

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../application/setting_controller.dart';
import '../application/chat_controller.dart'; // chatProvider
import '../../../core/db/data_manager.dart';
import '../../../core/config/deepseek_models.dart';
import '../../sync/presentation/sync_page.dart';

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
/// 若干 `if (...) _ParamInput(...)` 条件项。条件项一增一减，后面所有子项的
/// **位置**就整体平移，Flutter 会按位置把旧 State 复用到新位置上，于是
/// controller 里的内容跟着串位——实测「联网搜索」切成关闭后，temperature
/// 那一行显示出了百度 API Key 的值。
/// 加上按字段名生成的 Key 后，State 身份与字段绑定，不会再错位。
Key _k(String name) => ValueKey<String>('setting_$name');

/// 左侧标签与右侧控件的宽度配比（4.6 : 5.4，标签约占 46%）。
///
/// 原来两侧都用 150dp 定宽标签 + 剩余空间，问题是标签区按最长的那条
/// （「读取上方对话记录轮数」10 个字）撑开，在 360dp 屏上吃掉近一半宽度，
/// 右侧输入框只剩 ~160dp，「留空不限 | pd | pw | pm | py | YYYY-MM-DDtoYYYY-MM-DD」
/// 这类提示全被省略号截断。
/// 改成按比例分配后：标签仍逐行对齐（同一 flex），窄屏也不会反过来挤压输入框。
/// 配比取 4.6:5.4 是实测结果——360dp 屏下标签列约 138dp，正好容下最长的
/// 「读取上方对话记录轮数」（~137dp @12.5sp）不折行，而输入框仍有 ~176dp，
/// 比改动前的 ~160dp 宽，提示文字能多露一截。
/// 4:6 会让最长标签差几 dp 折成两行，行高因此参差，故不用。
const int _kLabelFlex = 46;
const int _kControlFlex = 54;

/// 标签与控件之间的最小间距。
///
/// 只有比例分配还不够：最长的标签正好占满标签列时，文字会贴到输入框边上
/// （实测「读取上方对话记录轮数」与输入框几乎无间隙）。留一条固定槽位既解决
/// 贴边，又给长标签一点余量——比例负责"大致各占多少"，间距负责"不许贴上"。
const double _kRowGap = 10;

/// 行内标签（与右侧控件同一基线的统一样式）
class _RowLabel extends StatelessWidget {
  final String text;
  const _RowLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(fontSize: 12.5, color: Color(0xFF666666)),
    );
  }
}

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
            backgroundColor: Color(0xFF4D6BFE),
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
        backgroundColor: err != null ? Color(0xFFFF4D4F) : Color(0xFF4D6BFE),
        duration: Duration(seconds: 2),
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
            child: Text('确定导入', style: TextStyle(color: Colors.red)),
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
        backgroundColor: err != null ? Color(0xFFFF4D4F) : Color(0xFF4D6BFE),
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = ref.watch(settingProvider);
    if (!ctrl.isLoaded) {
      return const Scaffold(
        backgroundColor: Colors.white,
        body: Center(
          child: CircularProgressIndicator(color: Color(0xFF4D6BFE)),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Color(0xFF333333)),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          '设置',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: Color(0xFF333333),
          ),
        ),
        centerTitle: true,
        actions: [
          TextButton(
            onPressed: _onSave,
            child: const Text(
              '保存',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: Color(0xFF4D6BFE),
              ),
            ),
          ),
        ],
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, color: Color(0xFFEEEEEE)),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: [
          const _SectionHeader(title: '必选鉴权参数', isFirst: true),
          _ApiKeyField(initialValue: ctrl.apiKey, onChanged: ctrl.setApiKey),

          const _SectionHeader(title: '模型选择配置'),
          _ModelSelector(initialValue: ctrl.model, onChanged: ctrl.setModel),
          // 模型选择器是整行控件，联网搜索是「标签 + 值」行；两者都靠左起排时
          // 上下只隔 10dp，视觉上会粘成一个块，且左边缘不对齐更显得挤。
          // 这里补一段间距把它们分开（同时给自定义模型的输入框留出余量）。
          const SizedBox(height: 12),
          _DropdownParam(
            key: _k('search_engine'),
            label: '联网搜索',
            value: _normalizeEngine(ctrl.searchEngine),
            items: const [
              DropdownMenuItem(
                value: 'deepseek',
                child: Text('DeepSeek 官方搜索'),
              ),
              DropdownMenuItem(value: 'baidu', child: Text('百度千帆搜索')),
              DropdownMenuItem(value: 'off', child: Text('关闭')),
            ],
            onChanged: ctrl.setSearchEngine,
          ),
          // DeepSeek 官方搜索用的是对话接口同一个 Key，不用再配第三方 Key；
          // 这里把结论直接摆出来，省得用户去找"搜索专用的 Key"在哪填。
          if (_normalizeEngine(ctrl.searchEngine) == 'deepseek')
            const _InfoRow(
              key: ValueKey('setting_search_deepseek_info'),
              label: '搜索鉴权',
              text: '复用上方 DeepSeek API Key；官方按次计费（5 元/1000 次）',
            ),
          if (_normalizeEngine(ctrl.searchEngine) == 'baidu')
            _ParamInput(
              key: _k('baidu_api_key'),
              label: '百度API Key',
              hint: '百度千帆 Bearer Token',
              initialValue: ctrl.baiduApiKey,
              onChanged: ctrl.setBaiduApiKey,
            ),
          if (_normalizeEngine(ctrl.searchEngine) != 'off')
            _ParamInput(
              key: _k('search_count'),
              label: '最大搜索条数',
              hint: 'AI 可指定条数，不会超过此上限',
              initialValue: ctrl.searchCount.toString(),
              onChanged: (v) => ctrl.setSearchCount(int.tryParse(v) ?? 5),
            ),
          if (_normalizeEngine(ctrl.searchEngine) != 'off')
            _ParamInput(
              key: _k('search_freshness'),
              label: '时间筛选',
              hint: _normalizeEngine(ctrl.searchEngine) == 'deepseek'
                  ? '留空不限 | pd | pw | pm | py | YYYY-MM-DDtoYYYY-MM-DD'
                  : '留空不限 | pd | pw | pm | py',
              initialValue: ctrl.searchFreshness,
              onChanged: ctrl.setSearchFreshness,
            ),
          // 「抓取正文」只有 DeepSeek 官方搜索有这个开关（need_content）
          if (_normalizeEngine(ctrl.searchEngine) == 'deepseek')
            _SwitchParam(
              key: _k('search_need_content'),
              label: '抓取网页正文',
              initialValue: ctrl.searchNeedContent,
              onChanged: ctrl.setSearchNeedContent,
            ),

          const _SectionHeader(title: '日常调优参数'),
          _ParamInput(
            key: _k('temperature'),
            label: 'temperature',
            hint: '0.0 ~ 2.0',
            initialValue: ctrl.temperature.toString(),
            onChanged: (v) => ctrl.setTemperature(double.tryParse(v) ?? 1.0),
          ),
          _ParamInput(
            key: _k('top_p'),
            label: 'top_p',
            hint: '0.0 ~ 1.0',
            initialValue: ctrl.topP.toString(),
            onChanged: (v) => ctrl.setTopP(double.tryParse(v) ?? 1.0),
          ),
          _ParamInput(
            key: _k('max_tokens'),
            label: 'max_tokens',
            hint: '最大输出 token 数（上限 384K）',
            initialValue: ctrl.maxTokens.toString(),
            onChanged: (v) => ctrl.setMaxTokens(int.tryParse(v) ?? 4096),
            formatter: (v) {
              final parsed = int.tryParse(v);
              if (parsed == null) return v;
              return parsed.clamp(1, 384000).toString();
            },
          ),
          _ParamInput(
            key: _k('stop'),
            label: 'stop',
            hint: '停止词，逗号分隔',
            initialValue: ctrl.stop,
            onChanged: ctrl.setStop,
          ),

          const _SectionHeader(title: '流式交互参数'),
          _SwitchParam(
            key: _k('stream'),
            label: 'stream',
            initialValue: ctrl.stream,
            onChanged: ctrl.setStream,
          ),
          // stream_options 仅在流式开启时显示
          if (ctrl.stream)
            _ParamInput(
              key: _k('stream_options'),
              label: 'stream_options',
              hint: 'JSON 格式',
              initialValue: ctrl.streamOptions,
              onChanged: ctrl.setStreamOptions,
            ),

          const _SectionHeader(title: '去重优化参数'),
          _ParamInput(
            key: _k('frequency_penalty'),
            label: 'frequency_penalty',
            hint: '-2.0 ~ 2.0',
            initialValue: ctrl.frequencyPenalty.toString(),
            onChanged: (v) =>
                ctrl.setFrequencyPenalty(double.tryParse(v) ?? 0.0),
          ),
          _ParamInput(
            key: _k('presence_penalty'),
            label: 'presence_penalty',
            hint: '-2.0 ~ 2.0',
            initialValue: ctrl.presencePenalty.toString(),
            onChanged: (v) =>
                ctrl.setPresencePenalty(double.tryParse(v) ?? 0.0),
          ),

          const _SectionHeader(title: '结构化输出参数'),
          _ParamInput(
            key: _k('response_format'),
            label: 'response_format',
            hint: 'text / json_object',
            initialValue: ctrl.responseFormat,
            onChanged: ctrl.setResponseFormat,
          ),

          const _SectionHeader(title: '深度推理参数'),
          _SwitchParam(
            key: _k('thinking'),
            label: 'thinking',
            initialValue: ctrl.thinking,
            onChanged: ctrl.setThinking,
          ),

          const _SectionHeader(title: '高级调试参数'),
          _SwitchParam(
            key: _k('logprobs'),
            label: 'logprobs',
            initialValue: ctrl.logprobs,
            onChanged: ctrl.setLogprobs,
          ),
          _ParamInput(
            key: _k('top_logprobs'),
            label: 'top_logprobs',
            hint: '0 ~ 20',
            initialValue: ctrl.topLogprobs.toString(),
            onChanged: (v) => ctrl.setTopLogprobs(int.tryParse(v) ?? 0),
          ),
          _ParamInput(
            key: _k('logit_bias'),
            label: 'logit_bias',
            hint: 'JSON 格式',
            initialValue: ctrl.logitBias,
            onChanged: ctrl.setLogitBias,
          ),
          _ParamInput(
            key: _k('n'),
            label: 'n',
            hint: '生成数量',
            initialValue: ctrl.n.toString(),
            onChanged: (v) => ctrl.setN(int.tryParse(v) ?? 1),
          ),

          const _SectionHeader(title: '上下文控制参数'),
          _ParamInput(
            key: _k('context_rounds'),
            label: '读取上方对话记录轮数',
            hint: '1 ~ 100，缩减上下文 token',
            initialValue: ctrl.contextRounds.toString(),
            onChanged: (v) => ctrl.setContextRounds(
              SettingController.clampContextRounds(int.tryParse(v) ?? 10),
            ),
          ),

          const _SectionHeader(title: '数据管理'),
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 12),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _onExport,
                    icon: const Icon(Icons.upload, size: 16),
                    label: const Text('导出数据库', style: TextStyle(fontSize: 13)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF4D6BFE),
                      side: const BorderSide(color: Color(0xFF4D6BFE)),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _onImport,
                    icon: const Icon(Icons.download, size: 16),
                    label: const Text('导入数据库', style: TextStyle(fontSize: 13)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.redAccent,
                      side: const BorderSide(color: Colors.redAccent),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: InkWell(
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const SyncPage()),
                );
              },
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    const Icon(Icons.sync, size: 18, color: Color(0xFF4D6BFE)),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '数据同步',
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w500,
                              color: Color(0xFF333333),
                            ),
                          ),
                          SizedBox(height: 2),
                          Text(
                            '与电脑上的 Web 服务双向同步，不用再导文件',
                            style: TextStyle(fontSize: 12, color: Color(0xFF999999)),
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.chevron_right, size: 18, color: Color(0xFFCCCCCC)),
                  ],
                ),
              ),
            ),
          ),

          // 底部留白：全局悬浮聊天球停在右下角（48dp 球 + 8dp 边距），
          // 会把列表最后一项压在下面——实测「导入数据库」按钮被挡住约一半宽，
          // 文字都看不全。这里一次性让出足够高度，内容不再滚进悬浮球的停靠区。
          const SizedBox(height: 96),
        ],
      ),
    );
  }
}

// ─── 页面子组件 ───

/// 分组标题
class _SectionHeader extends StatelessWidget {
  final String title;

  /// 是否是页面第一个分组：首组的 20dp 上边距纯粹是白缝
  /// （AppBar 下方本来就有 8dp 列表内边距），去掉让首屏能多露一行。
  final bool isFirst;

  const _SectionHeader({required this.title, this.isFirst = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(top: isFirst ? 4 : 20, bottom: 8),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: Color(0xFF4D6BFE),
        ),
      ),
    );
  }
}

/// API Key 输入框（带显隐切换）
class _ApiKeyField extends StatefulWidget {
  final String initialValue;
  final ValueChanged<String> onChanged;
  const _ApiKeyField({required this.initialValue, required this.onChanged});

  @override
  State<_ApiKeyField> createState() => _ApiKeyFieldState();
}

class _ApiKeyFieldState extends State<_ApiKeyField> {
  bool _obscured = true;
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F5F5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _controller,
              obscureText: _obscured,
              onChanged: widget.onChanged,
              style: const TextStyle(fontSize: 14, color: Color(0xFF333333)),
              decoration: const InputDecoration(
                hintText: '请输入 API Key',
                hintStyle: TextStyle(fontSize: 14, color: Color(0xFFBBBBBB)),
                border: InputBorder.none,
                contentPadding: EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
          GestureDetector(
            onTap: () => setState(() => _obscured = !_obscured),
            child: Icon(
              _obscured ? Icons.visibility_off : Icons.visibility,
              size: 20,
              color: const Color(0xFF999999),
            ),
          ),
        ],
      ),
    );
  }
}

/// 模型选择器（下拉 + 自定义输入）
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
  /// 真实 API 标识由 DropdownMenuItem 的 value 承载，不占界面位置。
  static String _labelFor(String id) =>
      DeepSeekModels.toDisplayName(id) ?? id;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: const Color(0xFFF5F5F5),
            borderRadius: BorderRadius.circular(10),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              isExpanded: true,
              value: _isCustom ? 'custom' : _value,
              style: const TextStyle(fontSize: 14, color: Color(0xFF333333)),
              items: [
                for (final id in DeepSeekModels.selectableIds)
                  DropdownMenuItem(value: id, child: Text(_labelFor(id))),
                const DropdownMenuItem(value: 'custom', child: Text('自定义模型...')),
              ],
              onChanged: (v) {
                if (v == null) return;
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
          ),
        ),
        if (_isCustom) ...[
          const SizedBox(height: 8),
          _ParamInput(
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

/// 通用文本参数输入框
class _ParamInput extends StatefulWidget {
  final String label;
  final String hint;
  final String initialValue;
  final ValueChanged<String> onChanged;

  /// 输入格式化器：用户输入后调用，返回与显示同步的值（如裁剪数字范围）
  final String? Function(String input)? formatter;

  const _ParamInput({
    super.key,
    required this.label,
    required this.hint,
    required this.initialValue,
    required this.onChanged,
    this.formatter,
  });

  @override
  State<_ParamInput> createState() => _ParamInputState();
}

class _ParamInputState extends State<_ParamInput> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Expanded(flex: _kLabelFlex, child: _RowLabel(widget.label)),
          const SizedBox(width: _kRowGap),
          Expanded(
            flex: _kControlFlex,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: const Color(0xFFF5F5F5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: TextField(
                controller: _controller,
                onChanged: _onChanged,
                style: const TextStyle(fontSize: 14, color: Color(0xFF333333)),
                decoration: InputDecoration(
                  hintText: widget.hint,
                  hintStyle: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFFBBBBBB),
                  ),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 10),
                  isDense: true,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 通用下拉参数（与 _ParamInput 同布局：左侧定宽标签 + 右侧控件）
class _DropdownParam extends StatelessWidget {
  final String label;
  final String value;
  final List<DropdownMenuItem<String>> items;
  final ValueChanged<String> onChanged;

  const _DropdownParam({
    super.key,
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Expanded(flex: _kLabelFlex, child: _RowLabel(label)),
          const SizedBox(width: _kRowGap),
          Expanded(
            flex: _kControlFlex,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: const Color(0xFFF5F5F5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  isExpanded: true,
                  isDense: true,
                  value: value,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  style: const TextStyle(
                    fontSize: 14,
                    color: Color(0xFF333333),
                  ),
                  items: items,
                  onChanged: (v) {
                    if (v != null) onChanged(v);
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 只读提示行（与 _ParamInput 同布局，右侧不是输入框而是一段说明文字）
class _InfoRow extends StatelessWidget {
  final String label;
  final String text;

  const _InfoRow({super.key, required this.label, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(flex: _kLabelFlex, child: _RowLabel(label)),
          const SizedBox(width: _kRowGap),
          Expanded(
            flex: _kControlFlex,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                text,
                style: const TextStyle(
                  fontSize: 12,
                  height: 1.35,
                  color: Color(0xFF999999),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 开关参数
class _SwitchParam extends StatefulWidget {
  final String label;
  final bool initialValue;
  final ValueChanged<bool> onChanged;

  const _SwitchParam({
    super.key,
    required this.label,
    required this.initialValue,
    required this.onChanged,
  });

  @override
  State<_SwitchParam> createState() => _SwitchParamState();
}

class _SwitchParamState extends State<_SwitchParam> {
  late bool _value;

  @override
  void initState() {
    super.initState();
    _value = widget.initialValue;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Expanded(flex: _kLabelFlex, child: _RowLabel(widget.label)),
          const SizedBox(width: _kRowGap),
          // 开关不像输入框需要占满，靠左排在控件列起点即可，
          // 这样开关位置与其它行的输入框左边缘对齐。
          Expanded(
            flex: _kControlFlex,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Switch(
                value: _value,
                activeTrackColor: const Color(0xFF4D6BFE),
                onChanged: (v) {
                  setState(() => _value = v);
                  widget.onChanged(v);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
