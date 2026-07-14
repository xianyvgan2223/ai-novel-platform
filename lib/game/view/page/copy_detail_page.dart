import 'package:flutter/material.dart';
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
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: Text(
          _copy?.copyName ?? '副本详情',
          style: const TextStyle(fontSize: 15),
        ),
        backgroundColor: Colors.white,
        elevation: 0.5,
        centerTitle: true,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : _buildContent(),
    );
  }

  Widget _buildContent() {
    if (_latestRecord == null && _charStories.isEmpty) {
      return const Center(
        child: Text(
          '暂无经历数据',
          style: TextStyle(fontSize: 13, color: Color(0xFF999999)),
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
          const Padding(
            padding: EdgeInsets.only(left: 2, bottom: 4),
            child: Text(
              '角色经历',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFF333333),
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
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _copy!.copyName,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF333333),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _formatTime(_copy!.createTime),
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF999999),
                  ),
                ),
              ],
            ),
          ),
          if (_latestRecord != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xFF4CAF50).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text(
                '已生成',
                style: TextStyle(fontSize: 10, color: Color(0xFF4CAF50)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSectionCard(String title, String content) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Color(0xFF333333),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            content,
            style: const TextStyle(
              fontSize: 12,
              color: Color(0xFF555555),
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCharStoryCard(_CharStoryInfo info) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
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
                  color: const Color(0xFF4A90D9).withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Text(
                  info.charName.isNotEmpty ? info.charName[0] : '?',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF4A90D9),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                info.charName,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF333333),
                ),
              ),
            ],
          ),
          if (info.story.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              info.story,
              style: const TextStyle(
                fontSize: 12,
                color: Color(0xFF555555),
                height: 1.6,
              ),
            ),
          ],
          if (info.skills.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Text(
              '技能',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Color(0xFF888888),
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
                    color: const Color(0xFFFF9800).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    s.skillDesc != null && s.skillDesc!.isNotEmpty
                        ? '${s.skillName}: ${s.skillDesc}'
                        : s.skillName,
                    style: const TextStyle(
                      fontSize: 10,
                      color: Color(0xFFE65100),
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
          if (info.equipment.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Text(
              '装备',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Color(0xFF888888),
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
                    color: const Color(0xFF9C27B0).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    e.equipAttr != null && e.equipAttr!.isNotEmpty
                        ? '${e.equipName}: ${e.equipAttr}'
                        : e.equipName,
                    style: const TextStyle(
                      fontSize: 10,
                      color: Color(0xFF6A1B9A),
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
