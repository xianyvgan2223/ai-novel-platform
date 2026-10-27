import 'package:flutter/material.dart';
import 'package:deepseekapp/core/theme/app_palette.dart';
import 'package:deepseekapp/features/game/novel_game/model/entity/copy_entity.dart';
import 'package:deepseekapp/features/game/novel_game/model/entity/character_entity.dart';
import 'package:deepseekapp/features/game/novel_game/model/repo/copy_repository.dart';
import 'package:deepseekapp/features/game/novel_game/model/repo/character_repository.dart';

class CopyEditPage extends StatefulWidget {
  final CopyEntity copy;

  const CopyEditPage({super.key, required this.copy});

  @override
  State<CopyEditPage> createState() => _CopyEditPageState();
}

class _CopyEditPageState extends State<CopyEditPage> {
  final _copyRepo = CopyRepository();
  final _charRepo = CharacterRepository();
  final _nameCtrl = TextEditingController();
  final _bgCtrl = TextEditingController();

  String _selectedStyle = '默认';
  List<CharacterEntity> _attachedChars = [];
  bool _loading = true;
  bool _saving = false;

  static const _styles = ['默认', '热血', '悬疑', '幽默', '深沉', '浪漫'];

  @override
  void initState() {
    super.initState();
    _nameCtrl.text = widget.copy.copyName;

    final config = _parseModelConfig(widget.copy.modelConfig);
    _bgCtrl.text = config['background'] ?? '';
    _selectedStyle = config['style'] ?? '默认';

    _loadAttachedChars();
  }

  Future<void> _loadAttachedChars() async {
    try {
      final chars = await _charRepo.getCharacters();
      // 通过 char_copy_story 表判断哪些角色关联了这个副本
      final stories = await _copyRepo.getCharStoriesByCopyId(
        widget.copy.id ?? 0,
      );
      final attachedIds = stories.map((s) => s.charId).toSet();
      setState(() {
        _attachedChars = chars
            .where((c) => attachedIds.contains(c.id))
            .toList();
        _loading = false;
      });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  Map<String, String> _parseModelConfig(String? json) {
    if (json == null || json.isEmpty) return {};
    try {
      final map = <String, String>{};
      final cleaned = json.trim();
      if (cleaned.startsWith('{') && cleaned.endsWith('}')) {
        final inner = cleaned.substring(1, cleaned.length - 1);
        int depth = 0, start = 0;
        for (int i = 0; i < inner.length; i++) {
          if (inner[i] == '{') depth++;
          if (inner[i] == '}') depth--;
          if (inner[i] == ',' && depth == 0) {
            final part = inner.substring(start, i);
            final colonIdx = part.indexOf(':');
            if (colonIdx > 0) {
              final key = part
                  .substring(0, colonIdx)
                  .trim()
                  .replaceAll('"', '');
              final value = part
                  .substring(colonIdx + 1)
                  .trim()
                  .replaceAll('"', '');
              if (key.isNotEmpty) map[key] = value;
            }
            start = i + 1;
          }
        }
        if (start < inner.length) {
          final part = inner.substring(start);
          final colonIdx = part.indexOf(':');
          if (colonIdx > 0) {
            final key = part.substring(0, colonIdx).trim().replaceAll('"', '');
            final value = part
                .substring(colonIdx + 1)
                .trim()
                .replaceAll('"', '');
            if (key.isNotEmpty) map[key] = value;
          }
        }
      }
      return map;
    } catch (_) {
      return {};
    }
  }

  String _encodeModelConfig() {
    final parts = <String>[];
    if (_bgCtrl.text.isNotEmpty) {
      parts.add('"background":"${_bgCtrl.text}"');
    }
    if (_selectedStyle != '默认') {
      parts.add('"style":"$_selectedStyle"');
    }
    return parts.isEmpty ? '{}' : '{$parts}';
  }

  Future<void> _save() async {
    if (_nameCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请填写副本名称')));
      return;
    }

    setState(() => _saving = true);
    try {
      final copy = widget.copy;
      copy.copyName = _nameCtrl.text.trim();
      copy.modelConfig = _encodeModelConfig();
      await _copyRepo.updateCopy(copy);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('保存失败: $e')));
      }
    } finally {
      setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _bgCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Scaffold(
      backgroundColor: p.background,
      appBar: AppBar(
        title: const Text('编辑副本', style: TextStyle(fontSize: 15)),
        backgroundColor: p.surface,
        elevation: p.isDark ? 0 : 0.5,
        centerTitle: true,
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  )
                : const Text('保存', style: TextStyle(fontSize: 13)),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                _buildSection('基本信息', [
                  _buildField('副本名称', _nameCtrl, hint: '请输入副本名称'),
                ]),
                const SizedBox(height: 8),
                _buildSection('故事设定', [
                  _buildField(
                    '背景设定',
                    _bgCtrl,
                    hint: '修仙世界、末日废土...',
                    maxLines: 3,
                  ),
                  _buildStyleDropdown(),
                ]),
                if (_attachedChars.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _buildCharList(),
                ],
              ],
            ),
    );
  }

  Widget _buildSection(String title, List<Widget> children) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(8),
        border: p.isDark ? Border.all(color: p.border) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: p.textPrimary,
            ),
          ),
          const SizedBox(height: 10),
          ...children,
        ],
      ),
    );
  }

  Widget _buildField(
    String label,
    TextEditingController ctrl, {
    String? hint,
    int maxLines = 1,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: ctrl,
        maxLines: maxLines,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          labelStyle: const TextStyle(fontSize: 12),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 10,
            vertical: 8,
          ),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
          isDense: true,
        ),
      ),
    );
  }

  Widget _buildStyleDropdown() {
    final p = context.palette;
    return DropdownButtonFormField<String>(
      initialValue: _selectedStyle,
      decoration: InputDecoration(
        labelText: '故事风格',
        labelStyle: const TextStyle(fontSize: 12),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
        isDense: true,
      ),
      style: TextStyle(fontSize: 13, color: p.textPrimary),
      items: _styles.map((s) {
        return DropdownMenuItem(
          value: s,
          child: Text(s, style: const TextStyle(fontSize: 12)),
        );
      }).toList(),
      onChanged: (v) {
        if (v != null) setState(() => _selectedStyle = v);
      },
    );
  }

  Widget _buildCharList() {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(8),
        border: p.isDark ? Border.all(color: p.border) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '已关联人物 (${_attachedChars.length})',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: p.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: _attachedChars.map((c) {
              return Chip(
                label: Text(c.charName, style: const TextStyle(fontSize: 11)),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}
