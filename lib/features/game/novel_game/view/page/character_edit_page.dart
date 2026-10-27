import 'package:flutter/material.dart';
import 'package:deepseekapp/core/theme/app_palette.dart';
import 'package:deepseekapp/features/game/novel_game/model/entity/character_entity.dart';
import 'package:deepseekapp/features/game/novel_game/model/entity/skill_entity.dart';
import 'package:deepseekapp/features/game/novel_game/model/entity/equipment_entity.dart';
import 'package:deepseekapp/features/game/novel_game/model/repo/character_repository.dart';
import 'package:deepseekapp/features/game/novel_game/model/repo/copy_repository.dart';
import 'package:deepseekapp/features/game/novel_game/view/page/copy_detail_page.dart';

class CharacterEditPage extends StatefulWidget {
  final CharacterEntity character;

  const CharacterEditPage({super.key, required this.character});

  @override
  State<CharacterEditPage> createState() => _CharacterEditPageState();
}

class _CharacterEditPageState extends State<CharacterEditPage> {
  final _charRepo = CharacterRepository();
  final _copyRepo = CopyRepository();
  final _nameCtrl = TextEditingController();
  final _descCtrl = TextEditingController();

  List<SkillEntity> _skills = [];
  List<EquipmentEntity> _equipment = [];
  List<_CopyStoryRef> _copyStories = [];
  bool _loading = true;
  bool _isEditing = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _nameCtrl.text = widget.character.charName;
    _descCtrl.text = widget.character.baseDesc ?? '';
    _loadData();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    try {
      final charId = widget.character.id ?? 0;
      _skills = await _charRepo.getSkillsByCharId(charId);
      _equipment = await _charRepo.getEquipmentByCharId(charId);

      final stories = await _charRepo.getCharStoriesByCharId(charId);
      final allCopies = await _copyRepo.getCopies();

      final refs = <_CopyStoryRef>[];
      for (final s in stories) {
        if (s.singleStory != null) {
          final copy = allCopies.where((c) => c.id == s.copyId);
          refs.add(
            _CopyStoryRef(
              copyId: s.copyId,
              copyName: copy.isNotEmpty ? copy.first.copyName : '未知副本',
              story: s.singleStory ?? '',
            ),
          );
        }
      }

      setState(() {
        _skills = _skills;
        _equipment = _equipment;
        _copyStories = refs;
        _loading = false;
      });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  Future<void> _saveEdit() async {
    if (_nameCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('角色名称不能为空')));
      return;
    }

    setState(() => _saving = true);
    try {
      widget.character.charName = _nameCtrl.text.trim();
      widget.character.baseDesc = _descCtrl.text.trim();
      await _charRepo.updateCharacter(widget.character);
      setState(() => _isEditing = false);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('保存失败：$e')));
      }
    } finally {
      setState(() => _saving = false);
    }
  }

  Future<void> _deleteCharacter() async {
    final p = context.palette;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.surfaceElevated,
        title: const Text('确认删除', style: TextStyle(fontSize: 15)),
        content: Text(
          '确定要删除「${widget.character.charName}」吗？\n相关技能和装备也会一并删除。',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: p.danger),
            child: const Text('删除'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        await _charRepo.deleteCharacter(widget.character.id ?? 0);
        if (mounted) Navigator.of(context).pop(true);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('删除失败：$e')));
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Scaffold(
      backgroundColor: p.background,
      appBar: AppBar(
        title: Text(
          _isEditing ? '编辑人物' : widget.character.charName,
          style: const TextStyle(fontSize: 15),
        ),
        backgroundColor: p.surface,
        elevation: p.isDark ? 0 : 0.5,
        centerTitle: true,
        actions: [
          if (_isEditing) ...[
            TextButton(
              onPressed: _saving ? null : _saveEdit,
              child: _saving
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 1.5),
                    )
                  : const Text('保存', style: TextStyle(fontSize: 13)),
            ),
          ] else ...[
            IconButton(
              icon: const Icon(Icons.edit_outlined, size: 18),
              onPressed: () => setState(() => _isEditing = true),
              tooltip: '编辑',
            ),
            IconButton(
              icon: Icon(
                Icons.delete_outline,
                size: 18,
                color: p.danger,
              ),
              onPressed: _deleteCharacter,
              tooltip: '删除',
            ),
          ],
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                _isEditing ? _buildEditInfoCard() : _buildInfoCard(),
                if (_skills.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _buildSectionCard(
                    '技能',
                    _skills.map((s) {
                      return '${s.skillName}${s.skillDesc != null && s.skillDesc!.isNotEmpty ? '：${s.skillDesc}' : ''}';
                    }).toList(),
                    const Color(0xFFFF9800),
                  ),
                ],
                if (_equipment.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _buildSectionCard(
                    '装备',
                    _equipment.map((e) {
                      return '${e.equipName}${e.equipAttr != null && e.equipAttr!.isNotEmpty ? '（${e.equipAttr}）' : ''}';
                    }).toList(),
                    const Color(0xFF9C27B0),
                  ),
                ],
                if (_copyStories.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.only(left: 2, bottom: 4),
                    child: Text(
                      '副本经历',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: p.textPrimary,
                      ),
                    ),
                  ),
                  for (final ref in _copyStories) ...[
                    const SizedBox(height: 6),
                    _buildStoryCard(ref),
                  ],
                ],
              ],
            ),
    );
  }

  Widget _buildInfoCard() {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(8),
        border: p.isDark ? Border.all(color: p.border) : null,
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: p.accent.withValues(alpha: 0.15),
            child: Text(
              widget.character.charName.isNotEmpty
                  ? widget.character.charName[0]
                  : '?',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: p.accent,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.character.charName,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: p.textPrimary,
                  ),
                ),
                if ((widget.character.baseDesc ?? '').isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    widget.character.baseDesc!,
                    style: TextStyle(
                      fontSize: 12,
                      color: p.textSecondary,
                      height: 1.4,
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

  Widget _buildEditInfoCard() {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(8),
        border: p.isDark ? Border.all(color: p.border) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _nameCtrl,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
            decoration: InputDecoration(
              labelText: '角色名称',
              labelStyle: const TextStyle(fontSize: 12),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 8,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
              ),
              isDense: true,
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _descCtrl,
            maxLines: 3,
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
              labelText: '人物描述',
              labelStyle: const TextStyle(fontSize: 12),
              hintText: '请输入人物描述...',
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 8,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
              ),
              isDense: true,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionCard(String title, List<String> items, Color accent) {
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
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: items.map((item) {
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: p.isDark ? 0.18 : 0.1),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  item,
                  style: TextStyle(fontSize: 11, color: accent),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildStoryCard(_CopyStoryRef ref) {
    final p = context.palette;
    return GestureDetector(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => CopyDetailPage(copyId: ref.copyId)),
        );
      },
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: p.surface,
          borderRadius: BorderRadius.circular(8),
          border: p.isDark ? Border.all(color: p.border) : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  ref.copyName,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: p.accent,
                  ),
                ),
                const Spacer(),
                Icon(
                  Icons.chevron_right,
                  size: 14,
                  color: p.textTertiary,
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              ref.story,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: p.textSecondary,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CopyStoryRef {
  final int copyId;
  final String copyName;
  final String story;

  _CopyStoryRef({
    required this.copyId,
    required this.copyName,
    required this.story,
  });
}
