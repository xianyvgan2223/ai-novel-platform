import 'package:flutter/material.dart';
import 'package:deepseekapp/core/theme/app_palette.dart';
import '../../model/entity/copy_entity.dart';
import '../../model/entity/copy_record_entity.dart';
import '../../model/entity/skill_entity.dart';
import '../../model/entity/equipment_entity.dart';
import '../../model/repo/copy_repository.dart';
import '../../model/repo/character_repository.dart';

class CopyDetailPage extends StatefulWidget {
  final int copyId;

  const CopyDetailPage({super.key, required this.copyId});

  @override
  State<CopyDetailPage> createState() => _CopyDetailPageState();
}

class _CopyDetailPageState extends State<CopyDetailPage> {
  final _copyRepo = CopyRepository();
  final _charRepo = CharacterRepository();

  CopyEntity? _copy;
  CopyRecordEntity? _latestRecord;
  List<_CharStoryInfo> _charStories = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    try {
      _copy = await _copyRepo.getCopyById(widget.copyId);
      _latestRecord = await CopyRepository().getLatestRecordByCopyId(
        widget.copyId,
      );

      final charStories = await _copyRepo.getCharStoriesByCopyId(widget.copyId);
      final chars = await _charRepo.getCharacters();

      final infos = <_CharStoryInfo>[];
      for (final cs in charStories) {
        final character = chars.where((c) => c.id == cs.charId);
        final charName = character.isNotEmpty
            ? character.first.charName
            : '未知角色';
        final skills = await _charRepo.getSkillsByCharId(cs.charId);
        final equipment = await _charRepo.getEquipmentByCharId(cs.charId);
        infos.add(
          _CharStoryInfo(
            charName: charName,
            story: cs.singleStory ?? '',
            skills: skills,
            equipment: equipment,
          ),
        );
      }

      setState(() {
        _charStories = infos;
        _loading = false;
      });
    } catch (e) {
      setState(() => _loading = false);
    }
  }

  String _formatTime(int timestamp) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
    return '${date.year}/${date.month}/${date.day} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Scaffold(
      backgroundColor: p.background,
      appBar: AppBar(
        title: Text(
          _copy?.copyName ?? '副本详情',
          style: const TextStyle(fontSize: 15),
        ),
        backgroundColor: p.surface,
        elevation: p.isDark ? 0 : 0.5,
        centerTitle: true,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : _buildContent(),
    );
  }

  Widget _buildContent() {
    final p = context.palette;
    if (_latestRecord == null && _charStories.isEmpty) {
      return Center(
        child: Text(
          '暂无经历数据',
          style: TextStyle(fontSize: 13, color: p.textTertiary),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        if (_copy != null) _buildInfoCard(),
        if (_latestRecord?.totalStory != null &&
            _latestRecord!.totalStory!.isNotEmpty) ...[
          const SizedBox(height: 8),
          _buildSectionCard('故事总纲', _latestRecord!.totalStory!),
        ],
        if (_charStories.isNotEmpty) ...[
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 4),
            child: Text(
              '角色经历',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: p.textPrimary,
              ),
            ),
          ),
          for (final cs in _charStories) ...[
            const SizedBox(height: 6),
            _buildCharStoryCard(cs),
          ],
        ],
      ],
    );
  }

  Widget _buildInfoCard() {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(8),
        border: p.isDark ? Border.all(color: p.border) : null,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _copy!.copyName,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: p.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _formatTime(_copy!.createTime),
                  style: TextStyle(
                    fontSize: 11,
                    color: p.textTertiary,
                  ),
                ),
              ],
            ),
          ),
          if (_latestRecord != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: p.successSoft,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '已生成',
                style: TextStyle(fontSize: 10, color: p.success),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSectionCard(String title, String content) {
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
          Text(
            content,
            style: TextStyle(
              fontSize: 12,
              color: p.textSecondary,
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCharStoryCard(_CharStoryInfo info) {
    final p = context.palette;
    final skillColor = p.isDark
        ? const Color(0xFFFFB74D)
        : const Color(0xFFE65100);
    final equipColor = p.isDark
        ? const Color(0xFFCE93D8)
        : const Color(0xFF6A1B9A);
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
          Row(
            children: [
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: p.accent.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Text(
                  info.charName.isNotEmpty ? info.charName[0] : '?',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: p.accent,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                info.charName,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: p.textPrimary,
                ),
              ),
            ],
          ),
          if (info.story.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              info.story,
              style: TextStyle(
                fontSize: 12,
                color: p.textSecondary,
                height: 1.6,
              ),
            ),
          ],
          if (info.skills.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              '技能',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: p.textTertiary,
              ),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: info.skills.map((s) {
                return Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFF9800).withValues(
                      alpha: p.isDark ? 0.18 : 0.1,
                    ),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    s.skillDesc != null && s.skillDesc!.isNotEmpty
                        ? '${s.skillName}: ${s.skillDesc}'
                        : s.skillName,
                    style: TextStyle(
                      fontSize: 10,
                      color: skillColor,
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
          if (info.equipment.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              '装备',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: p.textTertiary,
              ),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: info.equipment.map((e) {
                return Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF9C27B0).withValues(
                      alpha: p.isDark ? 0.18 : 0.1,
                    ),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    e.equipAttr != null && e.equipAttr!.isNotEmpty
                        ? '${e.equipName}: ${e.equipAttr}'
                        : e.equipName,
                    style: TextStyle(
                      fontSize: 10,
                      color: equipColor,
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ],
      ),
    );
  }
}

class _CharStoryInfo {
  final String charName;
  final String story;
  final List<SkillEntity> skills;
  final List<EquipmentEntity> equipment;

  _CharStoryInfo({
    required this.charName,
    required this.story,
    required this.skills,
    required this.equipment,
  });
}
