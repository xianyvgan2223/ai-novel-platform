/// lib/views/settings_page.dart
/// 设置页面 — 全量 DeepSeek API 参数可视化配置

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../application/setting_controller.dart';
import '../../../core/db/data_manager.dart';
import 'chat_page.dart'; // chatProvider

/// SettingController Riverpod Provider
final settingProvider = ChangeNotifierProvider<SettingController>(
  (ref) => SettingController(),
);

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
          const _SectionHeader(title: '必选鉴权参数'),
          _ApiKeyField(initialValue: ctrl.apiKey, onChanged: ctrl.setApiKey),

          const _SectionHeader(title: '模型选择配置'),
          _ModelSelector(initialValue: ctrl.model, onChanged: ctrl.setModel),
          _SwitchParam(
            label: '联网搜索 (web_search)',
            initialValue: ctrl.webSearch,
            onChanged: ctrl.setWebSearch,
          ),
          if (ctrl.webSearch)
            _ParamInput(
              label: '百度API Key',
              hint: '百度千帆 Bearer Token',
              initialValue: ctrl.baiduApiKey,
              onChanged: ctrl.setBaiduApiKey,
            ),
          if (ctrl.webSearch)
            _ParamInput(
              label: '最大搜索条数',
              hint: 'AI 可指定条数，不会超过此上限',
              initialValue: ctrl.searchCount.toString(),
              onChanged: (v) => ctrl.setSearchCount(int.tryParse(v) ?? 5),
            ),
          if (ctrl.webSearch)
            _ParamInput(
              label: '时间筛选',
              hint: '留空不限 | pd | pw | pm | py | YYYY-MM-DDtoYYYY-MM-DD',
              initialValue: ctrl.searchFreshness,
              onChanged: ctrl.setSearchFreshness,
            ),

          const _SectionHeader(title: '日常调优参数'),
          _ParamInput(
            label: 'temperature',
            hint: '0.0 ~ 2.0',
            initialValue: ctrl.temperature.toString(),
            onChanged: (v) => ctrl.setTemperature(double.tryParse(v) ?? 1.0),
          ),
          _ParamInput(
            label: 'top_p',
            hint: '0.0 ~ 1.0',
            initialValue: ctrl.topP.toString(),
            onChanged: (v) => ctrl.setTopP(double.tryParse(v) ?? 1.0),
          ),
          _ParamInput(
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
            label: 'stop',
            hint: '停止词，逗号分隔',
            initialValue: ctrl.stop,
            onChanged: ctrl.setStop,
          ),

          const _SectionHeader(title: '流式交互参数'),
          _SwitchParam(
            label: 'stream',
            initialValue: ctrl.stream,
            onChanged: ctrl.setStream,
          ),
          // stream_options 仅在流式开启时显示
          if (ctrl.stream)
            _ParamInput(
              label: 'stream_options',
              hint: 'JSON 格式',
              initialValue: ctrl.streamOptions,
              onChanged: ctrl.setStreamOptions,
            ),

          const _SectionHeader(title: '去重优化参数'),
          _ParamInput(
            label: 'frequency_penalty',
            hint: '-2.0 ~ 2.0',
            initialValue: ctrl.frequencyPenalty.toString(),
            onChanged: (v) =>
                ctrl.setFrequencyPenalty(double.tryParse(v) ?? 0.0),
          ),
          _ParamInput(
            label: 'presence_penalty',
            hint: '-2.0 ~ 2.0',
            initialValue: ctrl.presencePenalty.toString(),
            onChanged: (v) =>
                ctrl.setPresencePenalty(double.tryParse(v) ?? 0.0),
          ),

          const _SectionHeader(title: '结构化输出参数'),
          _ParamInput(
            label: 'response_format',
            hint: 'text / json_object',
            initialValue: ctrl.responseFormat,
            onChanged: ctrl.setResponseFormat,
          ),

          const _SectionHeader(title: '深度推理参数'),
          _SwitchParam(
            label: 'thinking',
            initialValue: ctrl.thinking,
            onChanged: ctrl.setThinking,
          ),

          const _SectionHeader(title: '高级调试参数'),
          _SwitchParam(
            label: 'logprobs',
            initialValue: ctrl.logprobs,
            onChanged: ctrl.setLogprobs,
          ),
          _ParamInput(
            label: 'top_logprobs',
            hint: '0 ~ 20',
            initialValue: ctrl.topLogprobs.toString(),
            onChanged: (v) => ctrl.setTopLogprobs(int.tryParse(v) ?? 0),
          ),
          _ParamInput(
            label: 'logit_bias',
            hint: 'JSON 格式',
            initialValue: ctrl.logitBias,
            onChanged: ctrl.setLogitBias,
          ),
          _ParamInput(
            label: 'n',
            hint: '生成数量',
            initialValue: ctrl.n.toString(),
            onChanged: (v) => ctrl.setN(int.tryParse(v) ?? 1),
          ),

          const _SectionHeader(title: '上下文控制参数'),
          _ParamInput(
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

          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

// ─── 页面子组件 ───

/// 分组标题
class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 8),
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
    _value = widget.initialValue;
    _isCustom = ![
      'deepseek-v4-flash',
      'deepseek-v4-pro',
      'deepseek-reasoner',
    ].contains(_value);
    _customCtrl = TextEditingController(text: _isCustom ? _value : '');
  }

  @override
  void dispose() {
    _customCtrl.dispose();
    super.dispose();
  }

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
              items: const [
                DropdownMenuItem(
                  value: 'deepseek-v4-flash',
                  child: Text('deepseek-v4-flash'),
                ),
                DropdownMenuItem(
                  value: 'deepseek-v4-pro',
                  child: Text('deepseek-v4-pro'),
                ),
                DropdownMenuItem(
                  value: 'deepseek-reasoner',
                  child: Text('deepseek-reasoner'),
                ),
                DropdownMenuItem(value: 'custom', child: Text('自定义模型...')),
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
          SizedBox(
            width: 150,
            child: Text(
              widget.label,
              style: const TextStyle(fontSize: 13, color: Color(0xFF666666)),
            ),
          ),
          Expanded(
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

/// 开关参数
class _SwitchParam extends StatefulWidget {
  final String label;
  final bool initialValue;
  final ValueChanged<bool> onChanged;

  const _SwitchParam({
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
          SizedBox(
            width: 150,
            child: Text(
              widget.label,
              style: const TextStyle(fontSize: 13, color: Color(0xFF666666)),
            ),
          ),
          Switch(
            value: _value,
            activeTrackColor: const Color(0xFF4D6BFE),
            onChanged: (v) {
              setState(() => _value = v);
              widget.onChanged(v);
            },
          ),
        ],
      ),
    );
  }
}
