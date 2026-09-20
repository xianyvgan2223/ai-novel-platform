import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../../../shared/dialog_utils.dart';
import '../../controller/battle_controller.dart';
import '../../model/battle_model.dart';
import 'battle_setting_page.dart';
import 'battle_history_page.dart';

/// AI 写战斗主页面 — 输入要素 + 流式生成 + 历史查看
class AiBattlePage extends StatefulWidget {
  const AiBattlePage({super.key});

  @override
  State<AiBattlePage> createState() => _AiBattlePageState();
}

class _AiBattlePageState extends State<AiBattlePage> {
  final BattleController _controller = BattleController();
  final TextEditingController _skillsCtrl = TextEditingController();
  final TextEditingController _sceneCtrl = TextEditingController();
  final TextEditingController _resultCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onControllerChange);
    _controller.loadHistory();

    _skillsCtrl.addListener(() => _controller.updateSkills(_skillsCtrl.text));
    _sceneCtrl.addListener(() => _controller.updateScene(_sceneCtrl.text));
    _resultCtrl.addListener(() => _controller.updateResult(_resultCtrl.text));
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChange);
    _controller.dispose();
    _skillsCtrl.dispose();
    _sceneCtrl.dispose();
    _resultCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _onControllerChange() {
    if (mounted) setState(() {});
    // 流式输出时自动滚动到底部
    if (_controller.streamingText.isNotEmpty && _scrollCtrl.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollCtrl.hasClients) {
          _scrollCtrl.animateTo(
            _scrollCtrl.position.maxScrollExtent,
            duration: const Duration(milliseconds: 50),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  void _onGenerate() {
    _controller.generate();
  }

  void _onCancel() {
    _controller.cancelRequest();
  }

  void _onComplete() {
    _skillsCtrl.clear();
    _sceneCtrl.clear();
    _resultCtrl.clear();
    _controller.resetOutput();
    _controller.loadHistory();
  }

  /// 将历史记录的提示词重新填入输入框，不删除原记录
  void _loadSceneToInput(BattleScene scene) {
    _skillsCtrl.text = scene.characterSkills;
    _sceneCtrl.text = scene.battleSceneDesc;
    _resultCtrl.text = scene.battleResult;
    // 滚动到顶部让用户看到已填入的输入框
    if (_scrollCtrl.hasClients) {
      _scrollCtrl.animateTo(
        0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  /// 弹出大编辑框方便编辑输入内容
  void _showEnlargeDialog(TextEditingController ctrl, String hint) {
    final editCtrl = TextEditingController(text: ctrl.text);
    final screenH = MediaQuery.of(context).size.height;
    final screenW = MediaQuery.of(context).size.width;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        titlePadding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
        contentPadding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
        actionsPadding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        title: const Text(
          '编辑内容',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        content: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: screenH * 0.72,
            maxWidth: screenW * 0.92,
          ),
          child: TextField(
            controller: editCtrl,
            maxLines: null,
            expands: true,
            textAlignVertical: TextAlignVertical.top,
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: const TextStyle(
                fontSize: 13,
                color: Color(0xFFBBBBBB),
                height: 1.5,
              ),
              border: InputBorder.none,
              contentPadding: const EdgeInsets.fromLTRB(4, 2, 4, 2),
              filled: true,
              fillColor: const Color(0xFFFAFAFA),
            ),
            style: const TextStyle(fontSize: 13, height: 1.5),
          ),
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: () {
              if (!closeDialogSafely(ctx)) return;
              scheduleControllerDispose(editCtrl);
            },
            child: const Text('取消', style: TextStyle(fontSize: 12)),
          ),
          TextButton(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: () {
              if (!closeDialogSafely(ctx)) return;
              ctrl.text = editCtrl.text;
              scheduleControllerDispose(editCtrl);
            },
            child: const Text(
              '确定',
              style: TextStyle(fontSize: 12, color: Color(0xFFFF5722)),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isLoading = _controller.isLoading;
    final streaming = _controller.streamingText;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text(
          'AI 写战斗',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        backgroundColor: Colors.white,
        elevation: 0.5,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Color(0xFF333333)),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.history, color: Color(0xFF666666)),
            tooltip: '历史记录',
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => BattleHistoryPage(controller: _controller),
                ),
              );
              _controller.loadHistory();
              setState(() {});
            },
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined, color: Color(0xFF666666)),
            tooltip: '战斗设置',
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const BattleSettingPage()),
              );
              // 返回后触发重建
              setState(() {});
            },
          ),
        ],
      ),
      body: CupertinoScrollbar(
        controller: _scrollCtrl,
        thumbVisibility: true,
        thickness: 8,
        radius: const Radius.circular(4),
        child: SingleChildScrollView(
          controller: _scrollCtrl,
          child: Column(
            children: [
              // ── 输入区域 ──
              _buildInputArea(isLoading),

              // ── 分隔线 ──
              const Divider(height: 1, color: Color(0xFFEEEEEE)),

              // ── 输出 / 历史区域 ──
              if (streaming.isNotEmpty || isLoading)
                _buildStreamingContent(streaming, isLoading)
              else
                ..._buildHistoryContent(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInputArea(bool isLoading) {
    return Container(
      padding: const EdgeInsets.all(12),
      color: const Color(0xFFFAFAFA),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _skillsCtrl,
            enabled: !isLoading,
            maxLines: 2,
            decoration: _inputDecoration(
              '双方人物技能（如：张三的火焰刀、李四的冰霜剑）',
              onExpand: () =>
                  _showEnlargeDialog(_skillsCtrl, '双方人物技能（如：张三的火焰刀、李四的冰霜剑）'),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _sceneCtrl,
            enabled: !isLoading,
            maxLines: 2,
            decoration: _inputDecoration(
              '战斗场景（如：雪山之巅、暴雨中的古城）',
              onExpand: () =>
                  _showEnlargeDialog(_sceneCtrl, '战斗场景（如：雪山之巅、暴雨中的古城）'),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _resultCtrl,
            enabled: !isLoading,
            maxLines: 2,
            decoration: _inputDecoration(
              '战斗结果（如：张三以微弱优势获胜）',
              onExpand: () =>
                  _showEnlargeDialog(_resultCtrl, '战斗结果（如：张三以微弱优势获胜）'),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            height: 40,
            child: isLoading
                ? ElevatedButton.icon(
                    onPressed: _onCancel,
                    icon: const Icon(Icons.stop, size: 18),
                    label: const Text('停止生成'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFE53935),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  )
                : ElevatedButton.icon(
                    onPressed: _onGenerate,
                    icon: const Icon(Icons.auto_awesome, size: 18),
                    label: const Text('生成战斗场景'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFF5722),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  InputDecoration _inputDecoration(String hint, {VoidCallback? onExpand}) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(fontSize: 13, color: Color(0xFFBBBBBB)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: const BorderSide(color: Color(0xFFDDDDDD)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: const BorderSide(color: Color(0xFFDDDDDD)),
      ),
      filled: true,
      fillColor: Colors.white,
      isDense: true,
      suffixIcon: onExpand != null
          ? IconButton(
              icon: const Icon(Icons.open_in_full, size: 16),
              tooltip: '放大编辑',
              color: const Color(0xFF999999),
              onPressed: onExpand,
              constraints: const BoxConstraints(),
              padding: EdgeInsets.zero,
            )
          : null,
    );
  }

  Widget _buildStreamingContent(String text, bool isLoading) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 显示用户输入
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFF5F5F5),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '战斗要素',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    color: Color(0xFF666666),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _controller.userInput,
                  style: const TextStyle(
                    fontSize: 14,
                    color: Color(0xFF333333),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // 分隔
          Row(
            children: [
              const Text(
                '生成内容',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                  color: Color(0xFF666666),
                ),
              ),
              const SizedBox(width: 8),
              if (isLoading)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            text.isEmpty ? (isLoading ? '正在生成...' : '') : text,
            style: const TextStyle(
              fontSize: 15,
              height: 1.7,
              color: Color(0xFF222222),
            ),
          ),
          if (!isLoading && text.isNotEmpty) ...[
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              height: 40,
              child: ElevatedButton.icon(
                onPressed: _onComplete,
                icon: const Icon(Icons.check, size: 18),
                label: const Text('完成'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF4CAF50),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  List<Widget> _buildHistoryContent() {
    final history = _controller.history;
    if (history.isEmpty) {
      return [
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 64),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.local_fire_department,
                size: 48,
                color: Color(0xFFDDDDDD),
              ),
              SizedBox(height: 12),
              Text(
                '在上方输入战斗要素，点击生成',
                style: TextStyle(fontSize: 14, color: Color(0xFFBBBBBB)),
              ),
            ],
          ),
        ),
      ];
    }

    return [
      Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: history.map((scene) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _buildHistoryCard(scene),
            );
          }).toList(),
        ),
      ),
    ];
  }

  Widget _buildHistoryCard(BattleScene scene) {
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: Color(0xFFEEEEEE)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 头部：时间 + 重新生成 + 删除
            Row(
              children: [
                Expanded(
                  child: Text(
                    _formatTime(scene.createdAt),
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF999999),
                    ),
                  ),
                ),
                InkWell(
                  child: const Icon(
                    Icons.refresh,
                    size: 16,
                    color: Color(0xFF999999),
                  ),
                  onTap: () => _loadSceneToInput(scene),
                ),
                const SizedBox(width: 8),
                InkWell(
                  child: const Icon(
                    Icons.delete_outline,
                    size: 16,
                    color: Color(0xFFCCCCCC),
                  ),
                  onTap: () => _controller.removeFromHistory(scene.id!),
                ),
              ],
            ),
            const SizedBox(height: 6),
            // 用户输入摘要
            Text(
              scene.userInput,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, color: Color(0xFF666666)),
            ),
            if (scene.aiResult.isNotEmpty) ...[
              const SizedBox(height: 6),
              const Divider(height: 1, color: Color(0xFFF0F0F0)),
              const SizedBox(height: 6),
              Text(
                scene.aiResult,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14,
                  height: 1.5,
                  color: Color(0xFF222222),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _formatTime(String iso) {
    try {
      final dt = DateTime.parse(iso);
      return '${dt.month}/${dt.day} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return iso;
    }
  }
}
