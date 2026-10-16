import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../controller/outline_listen_controller.dart';
import '../../service/name_finder.dart';
import '../../service/outline_rename.dart';

/// 「一键改名」面板：把大纲里的人名 / 地名 / 门派名等**一次全换掉**。
///
/// 为什么要有它：写到一半想给主角改名（或者发现两个角色重名、地名撞车）时，
/// 手动在几十条事件里逐条找、逐条改，几乎一定会漏。这里的做法是：
/// 1. 打开就按离线规则列出**候选专名**（人物设定里的名字 + 姓氏 / 地名后缀规则）；
/// 2. 点候选即加入替换表，也可以手填任何词（不限于人名地名）；
/// 3. 每一条都实时显示「会影响多少个事件、替换多少处」，并列出具体位置
///    （大事件3 · 标题 / 小事件5 · 概要 + 上下文），确认后才真的改；
/// 4. 点「一键替换」后**大纲正文、章节行、伏笔清单、当前页面**一起改完并即时落库。
///
/// 替换规则是**纯文本替换**（中文没有词的边界），所以面板上如实显示
/// 「实际替换掉的文字」，让用户自己判断会不会误伤（例如「李云」也会命中
/// 「李云飞」里的那两个字）。
class OutlineRenameSheet extends StatefulWidget {
  final OutlineListenController controller;

  /// 打开面板时算好的候选专名（见 `_OutlineRenameSheetState._candidates` 的说明）
  final List<OutlineNameCandidate> candidates;

  const OutlineRenameSheet({
    super.key,
    required this.controller,
    required this.candidates,
  });

  @override
  State<OutlineRenameSheet> createState() => _OutlineRenameSheetState();
}

class _OutlineRenameSheetState extends State<OutlineRenameSheet> {
  final List<_RenameRule> _rules = [];

  /// 当前候选专名。
  ///
  /// 初值由页面在打开面板时算好传进来——**不能在 initState 里现算**：算完会
  /// notifyListeners，而此刻正是本面板构建中，页面收到通知后 markNeedsBuild
  /// 会直接抛「setState() or markNeedsBuild() called during build」。
  ///
  /// 改名之后必须整体换一份（见 [_refreshCandidates]）：控制器会按新正文重算
  /// （旧名字消失、新名字出现），留着旧快照的话底部标签就成了「刚改掉的名字
  /// 还挂着、新名字一个都没有」——这正是改名前那版的 bug。
  late List<OutlineNameCandidate> _candidates = widget.candidates;

  /// 按控制器里的最新候选刷新底部标签
  void _refreshCandidates() {
    final next = _controller.nameCandidates;
    if (listEquals(next, _candidates)) return;
    setState(() => _candidates = next);
  }

  int? _expandedRule;

  /// 是否正在替换（替换期间按钮置灰，避免连点两次）
  bool _replacing = false;

  /// 是否连**小说设定**一起改（主角 / 世界观等字段里的同名文字）。
  ///
  /// 为什么默认关：设定是作者自己填的，只改大纲不改设定是合理选择
  /// （设定里可能写的是笔名 / 别名）；而默认开着会顺手改掉用户没打算动的设定。
  bool _renameSettings = false;

  OutlineListenController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    // 默认给一条空行，用户可以直接手填
    _addRule();
  }

  @override
  void dispose() {
    for (final r in _rules) {
      r.dispose();
    }
    super.dispose();
  }

  void _addRule({String source = ''}) {
    final rule = _RenameRule(
      source: source,
      onChanged: () => setState(() {}),
    );
    _rules.add(rule);
    setState(() {});
  }

  void _removeRule(_RenameRule rule) {
    setState(() {
      _rules.remove(rule);
      rule.dispose();
    });
  }

  /// 候选点一下即加入替换表（已在表里的不再重复添加）
  void _useCandidate(OutlineNameCandidate candidate) {
    if (_rules.any((r) => r.source == candidate.text)) {
      _toast('「${candidate.text}」已经在替换表里了');
      return;
    }
    setState(() {
      final empty = _rules.where((r) => r.source.isEmpty).toList();
      if (empty.isNotEmpty) {
        empty.first.sourceCtrl.text = candidate.text;
      } else {
        _rules.add(
          _RenameRule(source: candidate.text, onChanged: () => setState(() {})),
        );
      }
    });
    _toast('已加入替换表：${candidate.text}（填写新名称后点「一键替换」）');
  }

  /// 当前有效的替换规则（两栏都填了、且不相同的才算）
  List<({String source, String target})> get _validRules => [
    for (final r in _rules)
      if (r.isValid) (source: r.source, target: r.target),
  ];

  /// 每条规则的影响预览（实时算）
  Map<String, OutlineRenameResult> get _previews => {
    for (final r in _rules)
      if (r.source.isNotEmpty) r.source: _controller.checkName(r.source),
  };

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
    );
  }

  Future<void> _detectWithAi() async {
    final added = await _controller.detectNamesWithAi();
    if (!mounted) return;
    // AI 识别出的新候选在控制器里，本面板要跟着换一份才看得到
    _refreshCandidates();
    _toast(
      added > 0
          ? 'AI 识别到 $added 个新的专名候选'
          : 'AI 没有识别到新的候选（可能是没配置 API Key，或结果与现有候选重复）',
    );
  }

  Future<void> _apply() async {
    final rules = _validRules;
    if (rules.isEmpty) {
      _toast('请先填写「原名称」与「新名称」');
      return;
    }
    final previews = _previews;
    final total = previews.values.fold(0, (sum, p) => sum + p.totalCount);
    if (total == 0) {
      _toast('这些名字在当前大纲里没有找到，无需替换');
      return;
    }
    final events = <int>{};
    for (final p in previews.values) {
      events.addAll(p.hits.map((h) => h.event.index));
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认一键改名'),
        content: Text(
          '将在 ${events.length} 个事件里替换 $total 处文字：\n\n'
          '${rules.map((r) => '「${r.source}」→「${r.target}」').join('\n')}\n\n'
          '大纲正文、事件标题与概要、伏笔清单${_renameSettings ? "、小说设定（主角 / 世界观）" : ""}'
          '会一起改掉，改完立即保存，不能再撤销。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确认替换'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _replacing = true);
    try {
      final outcome = await _controller.applyRenameRules(
        rules,
        updateSettings: _renameSettings,
      );
      if (!mounted) return;
      // 改完清空替换表：改名已生效，留着旧规则容易误点第二次。
      // 候选标签**必须一起重算**：控制器里那份已经按新正文刷新了
      // （旧名字没了、新名字出现若干次），面板里若是打开时的快照，
      // 用户会看到「刚改掉的名字还挂在下面、新名字一个都没有」。
      setState(() {
        for (final r in _rules) {
          r.dispose();
        }
        _rules
          ..clear()
          ..add(_RenameRule(onChanged: () => setState(() {})));
        _expandedRule = null;
      });
      _refreshCandidates();
      _toast(
        outcome.count > 0
            ? '已替换 ${outcome.count} 处，并立即保存（可用顶栏「撤回」改回来）'
            : '没有找到可替换的内容',
      );
    } catch (e) {
      if (mounted) _toast('替换失败：$e');
    } finally {
      if (mounted) setState(() => _replacing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 面板内实时预览：控制器改（改名落库）时刷新
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final previews = _previews;
        return _sheet(previews);
      },
    );
  }

  Widget _sheet(Map<String, OutlineRenameResult> previews) {
    final valid = _validRules;
    final total = valid.fold(
      0,
      (sum, r) => sum + (previews[r.source]?.totalCount ?? 0),
    );
    final events = <int>{};
    for (final r in valid) {
      final p = previews[r.source];
      if (p == null) continue;
      events.addAll(p.hits.map((h) => h.event.index));
    }

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.heightOf(context) * 0.9,
      ),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _header(),
          const Divider(height: 1),
          Flexible(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
              children: [
                _rulesSection(previews),
                const SizedBox(height: 14),
                _candidatesSection(),
              ],
            ),
          ),
          _footer(valid, total, events.length),
        ],
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 6),
      child: Row(
        children: [
          const Icon(
            Icons.drive_file_rename_outline,
            size: 17,
            color: Color(0xFF4D6BFE),
          ),
          const SizedBox(width: 6),
          const Text(
            '一键改名',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              '人名 / 地名 / 门派名，整篇一起换',
              style: TextStyle(fontSize: 11, color: Color(0xFF999999)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            color: const Color(0xFF999999),
            tooltip: '关闭',
            visualDensity: VisualDensity.compact,
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  /// 替换表：每行「原名称 → 新名称 + 影响预览」
  Widget _rulesSection(Map<String, OutlineRenameResult> previews) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text(
              '替换表',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFF333333),
              ),
            ),
            const SizedBox(width: 6),
            const Expanded(
              child: Text(
                '左栏填要改掉的写法，右栏填新名称',
                style: TextStyle(fontSize: 10.5, color: Color(0xFFBBBBBB)),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            TextButton.icon(
              onPressed: () => _addRule(),
              icon: const Icon(Icons.add, size: 15),
              label: const Text('加一条', style: TextStyle(fontSize: 12)),
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF4D6BFE),
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        for (var i = 0; i < _rules.length; i++)
          _ruleRow(i, _rules[i], previews[_rules[i].source]),
      ],
    );
  }

  Widget _ruleRow(
    int index,
    _RenameRule rule,
    OutlineRenameResult? preview,
  ) {
    final expanded = _expandedRule == index;
    final bad = rule.source.isNotEmpty && rule.target.isNotEmpty && !rule.isValid;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(8, 6, 6, 6),
      decoration: BoxDecoration(
        color: rule.isValid ? const Color(0xFFF8F9FF) : Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: bad ? const Color(0xFFFFCC80) : const Color(0xFFE8ECF4),
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _field(
                  controller: rule.sourceCtrl,
                  hint: '原名称，如 李云飞',
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 6),
                child: Icon(
                  Icons.arrow_forward,
                  size: 15,
                  color: Color(0xFF4D6BFE),
                ),
              ),
              Expanded(
                child: _field(
                  controller: rule.targetCtrl,
                  hint: '新名称，如 顾长风',
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 16),
                color: const Color(0xFF999999),
                tooltip: '删除这一条',
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.all(2),
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                onPressed: () => _removeRule(rule),
              ),
            ],
          ),
          if (rule.source.isNotEmpty) ...[
            const SizedBox(height: 2),
            InkWell(
              onTap: () => setState(
                () => _expandedRule = expanded ? null : index,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Icon(
                      preview == null || preview.isEmpty
                          ? Icons.search_off
                          : Icons.find_in_page_outlined,
                      size: 13,
                      color: preview == null || preview.isEmpty
                          ? const Color(0xFFBBBBBB)
                          : const Color(0xFF4D6BFE),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        preview == null || preview.isEmpty
                            ? '大纲里没有找到「${rule.source}」'
                            : '会影响 ${preview.eventCount} 个事件、替换 ${preview.totalCount} 处'
                                  '${expanded ? "（点一下收起）" : "（点一下看是哪儿）"}',
                        style: TextStyle(
                          fontSize: 10.5,
                          color: preview == null || preview.isEmpty
                              ? const Color(0xFF999999)
                              : const Color(0xFF4D6BFE),
                        ),
                      ),
                    ),
                    if (!rule.isValid && rule.target.isNotEmpty)
                      const Text(
                        '原名称与新名称相同',
                        style: TextStyle(
                          fontSize: 10,
                          color: Color(0xFFE65100),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (expanded && preview != null && !preview.isEmpty)
              _hitList(preview),
          ],
        ],
      ),
    );
  }

  /// 具体命中位置：改之前先看清楚改的是哪几句
  Widget _hitList(OutlineRenameResult preview) {
    final shown = preview.hits.take(OutlineRenameResult.previewLimit).toList();
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F7FB),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final hit in shown)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    hit.where,
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF4D6BFE),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${hit.context}（${hit.count} 处）',
                      style: const TextStyle(
                        fontSize: 10.5,
                        height: 1.35,
                        color: Color(0xFF666666),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (preview.hits.length > shown.length)
            Text(
              '还有 ${preview.hits.length - shown.length} 处未列出',
              style: const TextStyle(fontSize: 10, color: Color(0xFF999999)),
            ),
        ],
      ),
    );
  }

  /// 候选专名：点一下加入替换表
  Widget _candidatesSection() {
    final candidates = _candidates;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text(
              '可能的专名',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFF333333),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                candidates.isEmpty ? '没挑到候选' : '共 ${candidates.length} 个 · 点一下加入替换表',
                style: const TextStyle(fontSize: 10.5, color: Color(0xFFBBBBBB)),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            TextButton.icon(
              onPressed: _controller.detectingNames ? null : _detectWithAi,
              icon: _controller.detectingNames
                  ? const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.auto_awesome, size: 15),
              label: Text(
                _controller.detectingNames ? '识别中…' : 'AI 识别',
                style: const TextStyle(fontSize: 12),
              ),
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF4D6BFE),
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        if (candidates.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text(
              '没有自动挑出候选（正文太短或名字出现次数太少时会出现）。'
              '可以直接在上面的替换表里手填任何词——不限于人名地名。',
              style: TextStyle(
                fontSize: 11,
                height: 1.5,
                color: Color(0xFF999999),
              ),
            ),
          )
        else
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final c in candidates) _candidateChip(c),
            ],
          ),
      ],
    );
  }

  Widget _candidateChip(OutlineNameCandidate candidate) {
    final used = _rules.any((r) => r.source == candidate.text);
    return InkWell(
      onTap: () => _useCandidate(candidate),
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: used ? const Color(0xFFEFF3FF) : const Color(0xFFF5F7FB),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: used ? const Color(0xFF4D6BFE) : const Color(0xFFE3E8F2),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              candidate.text,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: used
                    ? const Color(0xFF4D6BFE)
                    : const Color(0xFF333333),
              ),
            ),
            const SizedBox(width: 4),
            Text(
              '${candidate.kind.label}·${candidate.count}',
              style: const TextStyle(fontSize: 9.5, color: Color(0xFF999999)),
            ),
            if (used) ...[
              const SizedBox(width: 3),
              const Icon(Icons.check, size: 12, color: Color(0xFF4D6BFE)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _footer(
    List<({String source, String target})> rules,
    int total,
    int eventCount,
  ) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: Color(0xFFEEEEEE))),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              rules.isEmpty
                  ? '填写「原名称 → 新名称」后即可一键替换'
                  : '将替换 $total 处，涉及 $eventCount 个事件；改完立即保存',
              style: TextStyle(
                fontSize: 11.5,
                color: total > 0
                    ? const Color(0xFF666666)
                    : const Color(0xFF999999),
              ),
            ),
            // 设定字段里的同名文字要不要一起改，交给用户定：
            // 候选里「人物设定里的主角」无视出现次数一直在榜上，
            // 改名后它还挂着旧名字，往往就是因为设定没跟着改
            InkWell(
              onTap: () => setState(() => _renameSettings = !_renameSettings),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    SizedBox(
                      width: 26,
                      height: 26,
                      child: Checkbox(
                        value: _renameSettings,
                        onChanged: (v) =>
                            setState(() => _renameSettings = v ?? false),
                        activeColor: const Color(0xFF4D6BFE),
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                    const SizedBox(width: 4),
                    const Expanded(
                      child: Text(
                        '同时改小说设定（主角 / 世界观里的同名文字）',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: Color(0xFF666666),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF666666),
                      side: const BorderSide(color: Color(0xFFDDDDDD)),
                      padding: const EdgeInsets.symmetric(vertical: 11),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: const Text('取消', style: TextStyle(fontSize: 13.5)),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: ElevatedButton.icon(
                    onPressed: (_replacing || rules.isEmpty || total == 0)
                        ? null
                        : _apply,
                    icon: _replacing
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.find_replace, size: 17),
                    label: Text(
                      _replacing ? '替换中…' : '一键替换',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF4D6BFE),
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: const Color(0xFFE8ECF4),
                      disabledForegroundColor: const Color(0xFF999999),
                      padding: const EdgeInsets.symmetric(vertical: 11),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _field({required TextEditingController controller, required String hint}) {
    return TextField(
      controller: controller,
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(fontSize: 12, color: Color(0xFFBBBBBB)),
        isDense: true,
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFFE3E8F2)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFFE3E8F2)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFF4D6BFE)),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      ),
      style: const TextStyle(fontSize: 12.5, color: Color(0xFF333333)),
    );
  }
}

/// 替换表里的一行：原名称 + 新名称
class _RenameRule {
  final TextEditingController sourceCtrl;
  final TextEditingController targetCtrl;
  final VoidCallback onChanged;

  _RenameRule({String source = '', String target = '', required this.onChanged})
      : sourceCtrl = TextEditingController(text: source),
        targetCtrl = TextEditingController(text: target) {
    sourceCtrl.addListener(onChanged);
    targetCtrl.addListener(onChanged);
  }

  String get source => sourceCtrl.text.trim();

  String get target => targetCtrl.text.trim();

  /// 有效规则：两栏都填了，且不是同一个词
  bool get isValid => source.isNotEmpty && target.isNotEmpty && source != target;

  void dispose() {
    sourceCtrl.removeListener(onChanged);
    targetCtrl.removeListener(onChanged);
    sourceCtrl.dispose();
    targetCtrl.dispose();
  }
}
