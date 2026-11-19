// lib/features/chat/presentation/settings_page.dart
// 设置页面 — 全量 DeepSeek API 参数可视化配置
//
// 页面结构（布局 v2）：
// - 浅灰底 + 白色圆角卡片，卡片只承担「内容块」，标题在卡外：
//   全页收敛成 9 个固定区块（外观 / 必选鉴权 / 模型与推理 / 联网搜索与工具 /
//   生成参数 / 流式交互 / 对话显示 / 调试与扩展 / 数据管理）；
// - 每行统一「左标签 + 右值」：值一律右对齐，下拉 = 值 + 小箭头、开关贴右，
//   所有右边缘都落在卡片 16dp 内边距这条线上；窄屏 / 大字号时长标签会自动
//   改成两行堆叠，保证 reasoning_effort 这类参数名不被省略号截断；
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
import '../../../core/theme/app_palette.dart';
import '../../../core/theme/theme_mode_controller.dart';
import '../../../core/widgets/settings_kit.dart';
import '../../sync/presentation/sync_page.dart';
import '../../update/presentation/update_changelog_page.dart';
import '../../update/presentation/update_page.dart';
import '../application/chat_controller.dart'; // chatProvider
import '../application/setting_controller.dart';

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
    final p = context.palette;
    try {
      await settingCtrl.saveSettings();
      // 清空对话控制器的配置缓存
      ref.read(chatProvider).clearSettingCache();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('设置已保存'),
            backgroundColor: p.accent,
            duration: const Duration(seconds: 1),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('保存失败（数据库不可用）'),
            backgroundColor: p.danger,
            duration: const Duration(seconds: 1),
          ),
        );
      }
    }
  }

  Future<void> _onExport() async {
    final ctrl = ref.read(settingProvider);
    final p = context.palette;
    // 先保存当前设置，确保数据最新
    await ctrl.saveSettings();
    // 清空缓存，确保数据库连接释放
    ref.read(chatProvider).clearSettingCache();

    final err = await DataManager.exportDatabase();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(err ?? '数据库已导出'),
        backgroundColor: err != null ? p.danger : p.accent,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _onImport() async {
    final p = context.palette;
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
            child: Text('确定导入', style: TextStyle(color: p.danger)),
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
        backgroundColor: err != null ? p.danger : p.accent,
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

  void _openChangelog() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const UpdateChangelogPage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
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
          thinking: c.thinking,
          // 这些是 Stateless 的 SettingsSelectRow 直接展示的值。
          // 只把它们纳入订阅：下拉选中后页面会重建，右侧当前值立即刷新；
          // 文本输入 / 开关仍由各自 StatefulWidget 持有，不会每敲一个字重建整页。
          reasoningEffort: c.reasoningEffort,
          responseFormat: c.responseFormat,
          toolChoice: c.toolChoice,
          safetyCheck: c.safetyCheck,
        ),
      ),
    );
    if (!form.isLoaded) {
      return Scaffold(
        backgroundColor: p.background,
        body: Center(child: CircularProgressIndicator(color: p.accent)),
      );
    }

    // 一次性读取当前值：只用来填各行的 initialValue，不建立依赖。
    final ctrl = ref.read(settingProvider);
    final engine = form.engine;
    final themeMode = ref.watch(themeModeProvider.select((c) => c.mode));
    final themeModeValue = ThemeModeController.encode(themeMode);

    return Scaffold(
      backgroundColor: p.background,
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
          // ── 0. 外观 ──
          const SettingsSectionHeader(
            icon: Icons.contrast_rounded,
            title: '外观',
            subtitle: '跟随系统，或手动选择浅色 / 深色',
            isFirst: true,
          ),
          SettingsCard(
            children: [
              SettingsSelectRow(
                key: _k('theme_mode'),
                label: '主题',
                value: themeModeValue,
                help: '只改变界面外观，不影响对话内容或 API 参数。跟随系统时会自动适配手机的浅色/深色模式。',
                options: const [
                  SettingsSelectOption('system', '跟随系统', shortLabel: '跟随系统'),
                  SettingsSelectOption('light', '浅色', shortLabel: '浅色'),
                  SettingsSelectOption('dark', '深色', shortLabel: '深色'),
                ],
                onChanged: (v) {
                  ref
                      .read(themeModeProvider)
                      .setMode(ThemeModeController.parse(v));
                },
              ),
            ],
          ),

          // ── 1. 必选鉴权 ──
          const SettingsSectionHeader(
            icon: Icons.vpn_key_rounded,
            title: '必选鉴权',
            subtitle: '对话与官方联网搜索共用同一个 Key',
          ),
          SettingsCard(
            children: [
              _ApiKeyCard(
                initialValue: ctrl.apiKey,
                onChanged: ctrl.setApiKey,
                help:
                    'DeepSeek 官方 API Key，仅保存在本机数据库，不会上传到其他服务器。'
                    '对话请求、DeepSeek 官方联网搜索共用这一把 Key；'
                    'Key 以 sk- 开头，可在 DeepSeek 开放平台创建。',
              ),
            ],
          ),

          // ── 2. 模型与推理 ──
          const SettingsSectionHeader(
            icon: Icons.memory_rounded,
            title: '模型与推理',
            subtitle: '官方 Chat Completions 的模型与思考参数',
          ),
          SettingsCard(
            children: [
              // 模型行内部还会按需渲染「自定义模型」行（同一张卡片）
              _ModelSelector(
                initialValue: ctrl.model,
                onChanged: ctrl.setModel,
                help:
                    'deepseek-flash 响应更快，适合日常对话；DeepSeek Pro（请求 ID deepseek-v4-pro）能力更强。'
                    '自定义模型会按原样发送模型 ID，由 API 或代理校验。',
              ),
              SettingsSwitchRow(
                key: _k('thinking'),
                label: 'thinking',
                subtitle: '先思考再回答',
                help:
                    '开启后模型会先输出 reasoning_content 思考过程，再给出最终回答；'
                    '思考内容会消耗输出 token。关闭时会显式发送 thinking={type:disabled}。',
                initialValue: ctrl.thinking,
                onChanged: ctrl.setThinking,
              ),
              SettingsSelectRow(
                key: _k('reasoning_effort'),
                label: 'reasoning_effort',
                value: ctrl.reasoningEffort,
                help:
                    '思考强度：none 关闭思考，low 快速思考，high 默认强度，max 最深思考。'
                    'none 会把 thinking 一并关闭；选择 low/high/max 时请求只发送 reasoning_effort，避免被 thinking 覆盖。',
                options: const [
                  SettingsSelectOption('none', 'none · 关闭思考'),
                  SettingsSelectOption('low', 'low · 快速'),
                  SettingsSelectOption('high', 'high · 默认'),
                  SettingsSelectOption('max', 'max · 最深'),
                ],
                onChanged: ctrl.setReasoningEffort,
              ),
            ],
          ),

          // ── 3. 联网搜索与工具 ──
          const SettingsSectionHeader(
            icon: Icons.travel_explore_rounded,
            title: '联网搜索与工具',
            subtitle: '模型可调用搜索工具获取实时信息',
          ),
          SettingsCard(
            children: [
              SettingsSelectRow(
                key: _k('search_engine'),
                label: '联网搜索',
                value: engine,
                help:
                    '开启后，聊天请求会注入一个 web_search function tool。'
                    'DeepSeek 官方搜索复用同一把 API Key；百度千帆需要单独填写 Key。',
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
                  hint: '百度千帆 Token',
                  help: '仅百度千帆搜索需要；DeepSeek 官方搜索不使用此 Key。',
                  initialValue: ctrl.baiduApiKey,
                  onChanged: ctrl.setBaiduApiKey,
                ),
              if (engine != 'off')
                SettingsTextRow(
                  key: _k('search_count'),
                  label: '最大搜索条数',
                  hint: '默认 5，上限 20',
                  help: '每次搜索注入上下文的结果条数。条数越多，回答信息越全，但 token 和耗时也越高。',
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
                  help:
                      '搜索接口的时间过滤参数，例如可填 day / week / month；具体格式由搜索来源决定，留空表示不限。',
                  initialValue: ctrl.searchFreshness,
                  onChanged: ctrl.setSearchFreshness,
                ),
              // 「抓取正文」只有 DeepSeek 官方搜索有这个开关（need_content）
              if (engine == 'deepseek')
                SettingsSwitchRow(
                  key: _k('search_need_content'),
                  label: '抓取网页正文',
                  subtitle: '抓取正文后回答更准，但更慢',
                  help: '开启后搜索接口会返回网页正文并注入上下文，回答更准确，但会显著增加 token 消耗。',
                  initialValue: ctrl.searchNeedContent,
                  onChanged: ctrl.setSearchNeedContent,
                ),
              if (engine != 'off')
                SettingsSelectRow(
                  key: _k('tool_choice'),
                  label: 'tool_choice',
                  value: ctrl.toolChoice,
                  help:
                      '官方工具调用策略：auto 由模型决定是否搜索；none 禁止调用工具；'
                      'required 强制调用搜索（思考模式下官方不支持 required，会自动降级为 auto）。',
                  options: const [
                    SettingsSelectOption('auto', 'auto · 由模型决定'),
                    SettingsSelectOption('none', 'none · 禁止工具'),
                    SettingsSelectOption('required', 'required · 必须搜索'),
                  ],
                  onChanged: ctrl.setToolChoice,
                ),
            ],
          ),

          // ── 4. 生成参数 ──
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
                help: '采样温度：越高越发散，越低越稳定。思考模式下官方会忽略此参数。',
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
                help:
                    '核采样：只从累计概率前 top_p 的 token 中采样。通常只调 temperature 或 top_p 其中一项；'
                    '不同模型/思考模式的实际生效值不同。',
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
                help:
                    '单次请求最多生成多少 token，官方允许范围 1~384000。'
                    '未设置时非思考默认 8K、思考默认 64K；值越大越慢、越贵。',
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
              SettingsSelectRow(
                key: _k('response_format'),
                label: 'response_format',
                value: ctrl.responseFormat == 'json_object'
                    ? 'json_object'
                    : 'text',
                help:
                    'text：普通文本；json_object：要求模型输出 JSON 对象。'
                    'JSON 模式仍需在系统提示词里明确要求模型输出 JSON，否则内容可能被清空。',
                options: const [
                  SettingsSelectOption('text', 'text · 普通文本'),
                  SettingsSelectOption('json_object', 'json_object · JSON'),
                ],
                onChanged: ctrl.setResponseFormat,
              ),
              SettingsTextRow(
                key: _k('stop'),
                label: 'stop',
                hint: '多个用逗号分隔',
                help: '最多 16 个停止字符串，命中任意一个即停止生成；用中文或英文逗号分隔。',
                initialValue: ctrl.stop,
                onChanged: ctrl.setStop,
              ),
            ],
          ),

          // ── 5. 流式交互 ──
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
                help: '开启后通过 SSE 逐块返回；关闭则等完整结果返回后一次性显示。',
                initialValue: ctrl.stream,
                onChanged: ctrl.setStream,
              ),
            ],
          ),
          // ── 6. 对话显示 ──
          const SettingsSectionHeader(
            icon: Icons.visibility_rounded,
            title: '对话显示',
            subtitle: '聊天页的用量与缓存信息',
          ),
          SettingsCard(
            children: [
              SettingsSwitchRow(
                key: _k('show_cache_hit'),
                label: '显示缓存命中',
                subtitle: '输入框上方与回答菜单显示命中率',
                help:
                    '关闭后隐藏输入框上方的「缓存 xx%」和每条回答「···」菜单里的'
                    '缓存命中明细；上下文占用与输入/输出 token 仍照常显示。'
                    '命中率来自 API usage，只影响展示，不影响请求与计费。',
                initialValue: ctrl.showCacheHit,
                onChanged: ctrl.setShowCacheHit,
              ),
            ],
          ),

          // ── 7. 调试与 DeepSeek 扩展 ──
          const SettingsSectionHeader(
            icon: Icons.psychology_rounded,
            title: '调试与扩展',
            subtitle: '日志概率、安全审核、会话标题与本地上下文',
          ),
          SettingsCard(
            children: [
              SettingsSwitchRow(
                key: _k('logprobs'),
                label: 'logprobs',
                subtitle: '返回每个 token 的对数概率',
                help:
                    '官方调试参数。开启后响应会包含每个输出 token 的对数概率；'
                    '流式模式下也会随 chunk 返回，普通聊天一般无需开启。',
                initialValue: ctrl.logprobs,
                onChanged: ctrl.setLogprobs,
              ),
              SettingsTextRow(
                key: _k('top_logprobs'),
                label: 'top_logprobs',
                hint: '0 ~ 20',
                help:
                    '每个输出位置额外返回概率最高的 N 个 token 及其对数概率，范围 0~20。'
                    '必须先开启 logprobs，否则 API 会拒绝。',
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                initialValue: ctrl.topLogprobs.toString(),
                onChanged: (v) => ctrl.setTopLogprobs(int.tryParse(v) ?? 0),
                formatter: (v) {
                  final parsed = int.tryParse(v);
                  if (parsed == null) return v;
                  return parsed.clamp(0, 20).toString();
                },
              ),
              SettingsSelectRow(
                key: _k('safety_check'),
                label: 'safety_check',
                value: ctrl.safetyCheck,
                help:
                    'DeepSeek 扩展风控参数。high 开启基础风控，审核模型输入与输出；'
                    'low 为默认检查，等同于不传此参数。开启 high 可能额外消耗安全 token。',
                options: const [
                  SettingsSelectOption('low', 'low · 默认检查'),
                  SettingsSelectOption('high', 'high · 基础风控'),
                ],
                onChanged: ctrl.setSafetyCheck,
              ),
              SettingsSwitchRow(
                key: _k('title_enabled'),
                label: 'title.enabled',
                subtitle: '返回会话标题',
                help:
                    'DeepSeek 扩展参数。开启后 API 会额外返回一个简短会话标题，'
                    '本 App 目前只发送参数，不自动覆盖已有会话标题。',
                initialValue: ctrl.titleEnabled,
                onChanged: ctrl.setTitleEnabled,
              ),
              SettingsTextRow(
                key: _k('user_id'),
                label: 'user_id',
                hint: '业务用户标识',
                help:
                    '用于区分业务侧用户的标识，建议仅使用字母、数字、下划线、连字符，'
                    'UTF-8 不超过 512 字节；不要填写真实姓名、手机号等隐私信息。留空则不发送。',
                initialValue: ctrl.userId,
                onChanged: ctrl.setUserId,
              ),
            ],
          ),

          // ── 8. 数据管理 ──
          const SettingsSectionHeader(
            icon: Icons.storage_rounded,
            title: '数据管理',
            subtitle: '本地数据库备份、多端同步与 App 更新',
          ),
          SettingsCard(
            children: [
              SettingsActionRow(
                icon: Icons.upload_rounded,
                iconColor: p.accent,
                softColor: p.accentSoft,
                title: '导出数据库',
                subtitle: '备份到本地文件',
                onTap: _onExport,
              ),
              SettingsActionRow(
                icon: Icons.download_rounded,
                iconColor: p.danger,
                softColor: p.dangerSoft,
                title: '导入数据库',
                titleColor: p.danger,
                subtitle: '从备份文件恢复，会覆盖现有数据',
                onTap: _onImport,
              ),
              SettingsActionRow(
                icon: Icons.sync_rounded,
                iconColor: p.accent,
                softColor: p.accentSoft,
                title: '整库同步',
                subtitle: '与电脑双向同步：手机整库上传，电脑修改也会回传',
                onTap: _openSync,
              ),
              SettingsActionRow(
                icon: Icons.system_update_rounded,
                iconColor: p.accent,
                softColor: p.accentSoft,
                title: '检查更新',
                subtitle: '从电脑同步服务下载并安装新版本',
                onTap: _openUpdate,
              ),
              SettingsActionRow(
                icon: Icons.history_rounded,
                iconColor: p.accent,
                softColor: p.accentSoft,
                title: '更新日志',
                subtitle: '回看每个版本的更新公告',
                onTap: _openChangelog,
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
                style: TextStyle(fontSize: 11, color: p.textTertiary),
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
  final String? help;

  const _ApiKeyCard({
    required this.initialValue,
    required this.onChanged,
    this.help,
  });

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
    final p = context.palette;
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
                  color: p.accentSoft,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.vpn_key_rounded, size: 17, color: p.accent),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'DeepSeek API Key',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: p.textPrimary,
                  ),
                ),
              ),
              if (widget.help != null) ...[
                const SizedBox(width: 4),
                SettingsHelpIcon(
                  title: 'DeepSeek API Key',
                  message: widget.help!,
                  color: p.textTertiary,
                ),
              ],
              _KeyStatusChip(configured: configured),
            ],
          ),
          const SizedBox(height: 12),
          AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            height: 46,
            padding: const EdgeInsets.fromLTRB(12, 0, 4, 0),
            decoration: BoxDecoration(
              color: p.surfaceMuted,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: _focused ? p.accent : p.border,
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
                    cursorColor: p.accent,
                    style: TextStyle(fontSize: 13.5, color: p.textSecondary),
                    onChanged: (v) {
                      // 首字符输入/清空时要刷新「已配置」徽标，所以这里 setState。
                      setState(() {});
                      widget.onChanged(v);
                    },
                    decoration: InputDecoration(
                      hintText: '填入以 sk- 开头的 Key',
                      hintStyle: TextStyle(
                        fontSize: 12.5,
                        color: p.textTertiary,
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
                    color: p.textTertiary,
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
    final p = context.palette;
    final Color color = configured ? p.success : p.textTertiary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
      decoration: BoxDecoration(
        color: configured ? p.successSoft : p.surfaceMuted,
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
              color: configured ? p.success : p.textTertiary,
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
  final String? help;
  const _ModelSelector({
    required this.initialValue,
    required this.onChanged,
    this.help,
  });

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
    final p = context.palette;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSelectRow(
          label: '模型',
          value: _isCustom ? 'custom' : _value,
          options: _options,
          help: widget.help,
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
          Divider(
            height: 1,
            thickness: 1,
            color: p.border,
            indent: kSettingsCardPadH,
            endIndent: kSettingsCardPadH,
          ),
          SettingsTextRow(
            key: _k('custom_model'),
            label: '自定义模型',
            hint: '输入模型标识',
            help: '直接填写官方或代理支持的模型 ID；未知标识会原样发给 API，由服务端校验。',
            initialValue: _customCtrl.text,
            onChanged: (v) => widget.onChanged(v),
          ),
        ],
      ],
    );
  }
}
