// lib/game/trpg/view/page/trpg_home_page.dart
// 跑团模拟器首页 — 战役存档列表

import 'package:flutter/material.dart';
import '../../controller/trpg_controller.dart';
import '../../data/trpg_db_service.dart';
import 'trpg_character_create_page.dart';
import 'trpg_game_page.dart';

class TrpgHomePage extends StatefulWidget {
  const TrpgHomePage({super.key});

  @override
  State<TrpgHomePage> createState() => _TrpgHomePageState();
}

class _TrpgHomePageState extends State<TrpgHomePage> {
  List<TrpgCampaign> _campaigns = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadCampaigns();
  }

  Future<void> _loadCampaigns() async {
    try {
      final campaigns = await TrpgDbService.getCampaigns();
      if (mounted) {
        setState(() {
          _campaigns = campaigns;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _createCampaign() async {
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) => const _CreateCampaignDialog(),
    );
    if (result == null) return;
    final name = result['name']!.trim();
    final dmPrompt = result['dm_prompt'] ?? '';

    final controller = TrpgController();
    final id = await controller.createCampaign(name: name, dmPrompt: dmPrompt);
    controller.dispose();

    if (mounted) {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => TrpgCharacterCreatePage(campaignId: id),
        ),
      );
      _loadCampaigns();
    }
  }

  Future<void> _openCampaign(TrpgCampaign campaign) async {
    final player = await TrpgDbService.getPlayerCharacter(campaign.id!);
    if (!mounted) return;

    if (player == null) {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => TrpgCharacterCreatePage(campaignId: campaign.id!),
        ),
      );
    } else {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => TrpgGamePage(campaignId: campaign.id!),
        ),
      );
    }
    _loadCampaigns();
  }

  Future<void> _deleteCampaign(TrpgCampaign campaign) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除战役', style: TextStyle(fontSize: 14)),
        content: const Text('确定删除该战役存档吗？', style: TextStyle(fontSize: 13)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消', style: TextStyle(fontSize: 13)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              '删除',
              style: TextStyle(fontSize: 13, color: Colors.red),
            ),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await TrpgDbService.deleteCampaign(campaign.id!);
      _loadCampaigns();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        toolbarHeight: 44,
        backgroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: const Text(
          '跑团模拟器',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: Color(0xFF333333),
          ),
        ),
        centerTitle: true,
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, color: Color(0xFFEEEEEE)),
        ),
      ),
      body: _loading
          ? const Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          : _campaigns.isEmpty
          ? _buildEmpty()
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _campaigns.length,
              itemBuilder: (_, i) {
                final c = _campaigns[i];
                return _CampaignCard(
                  campaign: c,
                  onTap: () => _openCampaign(c),
                  onDelete: () => _deleteCampaign(c),
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: _createCampaign,
        backgroundColor: const Color(0xFF4D6BFE),
        child: const Icon(Icons.add, color: Colors.white),
      ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.casino, size: 48, color: Color(0xFFCCCCCC)),
          const SizedBox(height: 12),
          const Text(
            '还没有战役存档',
            style: TextStyle(fontSize: 13, color: Color(0xFF999999)),
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: _createCampaign,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF4D6BFE),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            ),
            child: const Text('新建战役', style: TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }
}

class _CreateCampaignDialog extends StatefulWidget {
  const _CreateCampaignDialog();

  @override
  State<_CreateCampaignDialog> createState() => _CreateCampaignDialogState();
}

class _CreateCampaignDialogState extends State<_CreateCampaignDialog> {
  final _nameCtrl = TextEditingController();
  final _dmCtrl = TextEditingController();

  @override
  void dispose() {
    _nameCtrl.dispose();
    _dmCtrl.dispose();
    super.dispose();
  }

  /// 打开全屏编辑页，方便编写较长的冒险背景
  void _openFullscreenEditor() {
    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _FullscreenEditPage(
          title: '冒险背景',
          controller: _dmCtrl,
          hintText: '输入世界观、剧情背景、初始场景等，会喂给主持人（DM）…',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('新建战役', style: TextStyle(fontSize: 14)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(
                labelText: '战役名称',
                labelStyle: TextStyle(fontSize: 13),
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
              ),
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _dmCtrl,
              maxLines: 4,
              decoration: InputDecoration(
                labelText: '冒险背景（可选，喂给主持人）',
                labelStyle: const TextStyle(fontSize: 13),
                border: const OutlineInputBorder(),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                alignLabelWithHint: true,
                suffixIcon: IconButton(
                  onPressed: _openFullscreenEditor,
                  tooltip: '全屏编辑',
                  icon: const Icon(Icons.open_in_full, size: 18),
                ),
              ),
              style: const TextStyle(fontSize: 13),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消', style: TextStyle(fontSize: 13)),
        ),
        TextButton(
          onPressed: () {
            if (_nameCtrl.text.trim().isEmpty) return;
            Navigator.of(context).pop({
              'name': _nameCtrl.text.trim(),
              'dm_prompt': _dmCtrl.text.trim(),
            });
          },
          child: const Text(
            '创建',
            style: TextStyle(fontSize: 13, color: Color(0xFF4D6BFE)),
          ),
        ),
      ],
    );
  }
}

class _CampaignCard extends StatelessWidget {
  final TrpgCampaign campaign;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _CampaignCard({
    required this.campaign,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.04),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: const Color(0xFF4D6BFE).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                alignment: Alignment.center,
                child: const Icon(
                  Icons.casino,
                  size: 20,
                  color: Color(0xFF4D6BFE),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      campaign.name,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF333333),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      campaign.scene.isEmpty
                          ? '点击开始冒险'
                          : campaign.scene,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF999999),
                      ),
                    ),
                  ],
                ),
              ),
              GestureDetector(
                onTap: onDelete,
                child: const Icon(
                  Icons.close,
                  size: 16,
                  color: Color(0xFFCCCCCC),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 全屏编辑页 — 用于编辑较长的冒险背景等内容（共享同一个输入控制器）
class _FullscreenEditPage extends StatefulWidget {
  final String title;
  final TextEditingController controller;
  final String hintText;

  const _FullscreenEditPage({
    required this.title,
    required this.controller,
    this.hintText = '',
  });

  @override
  State<_FullscreenEditPage> createState() => _FullscreenEditPageState();
}

class _FullscreenEditPageState extends State<_FullscreenEditPage> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        toolbarHeight: 44,
        backgroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Text(
          widget.title,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: Color(0xFF333333),
          ),
        ),
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.close, size: 20, color: Color(0xFF666666)),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text(
              '完成',
              style: TextStyle(fontSize: 13, color: Color(0xFF4D6BFE)),
            ),
          ),
        ],
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, color: Color(0xFFEEEEEE)),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: TextField(
          controller: widget.controller,
          maxLines: null,
          expands: true,
          textAlignVertical: TextAlignVertical.top,
          autofocus: true,
          style: const TextStyle(
            fontSize: 14,
            height: 1.6,
            color: Color(0xFF333333),
          ),
          decoration: InputDecoration(
            hintText: widget.hintText,
            hintStyle: const TextStyle(fontSize: 13, color: Color(0xFFBBBBBB)),
            border: InputBorder.none,
            contentPadding: EdgeInsets.zero,
          ),
        ),
      ),
    );
  }
}
