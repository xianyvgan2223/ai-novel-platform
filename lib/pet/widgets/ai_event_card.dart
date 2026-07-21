import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../pet_state.dart';
import '../providers/pet_provider.dart';

/// AI随机事件交互卡片
class AiEventCard extends ConsumerStatefulWidget {
  const AiEventCard({super.key});

  @override
  ConsumerState<AiEventCard> createState() => _AiEventCardState();
}

class _AiEventCardState extends ConsumerState<AiEventCard> {
  final TextEditingController _customCtrl = TextEditingController();
  bool _showCustomInput = false;

  @override
  void dispose() {
    _customCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(petProvider);
    final event = controller.currentEvent;
    final theme = Theme.of(context);

    if (event == null) {
      return _buildTriggerCard(controller, theme);
    }

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 事件类别标签
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: _categoryColor(event.category).withAlpha(25),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    event.category.label,
                    style: TextStyle(
                      fontSize: 12,
                      color: _categoryColor(event.category),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const Spacer(),
                Icon(Icons.auto_awesome, size: 18, color: theme.colorScheme.primary),
              ],
            ),
            const SizedBox(height: 12),
            // 事件标题
            Text(
              event.title,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            // 事件描述
            Text(
              event.description,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: Colors.grey[700],
                height: 1.5,
              ),
            ),
            const SizedBox(height: 20),
            // 预设操作选项
            ...event.presetOptions.map(
              (option) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: () => _respond(option),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: Text(option),
                  ),
                ),
              ),
            ),
            // 自定义输入决策
            if (_showCustomInput) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _customCtrl,
                decoration: InputDecoration(
                  hintText: '输入你想对小宠说的话或做的事...',
                  hintStyle: TextStyle(fontSize: 14, color: Colors.grey[400]),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.send, size: 20),
                    onPressed: _submitCustomResponse,
                  ),
                ),
                maxLines: 2,
                minLines: 1,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _submitCustomResponse(),
              ),
            ],
            if (!_showCustomInput)
              TextButton.icon(
                onPressed: () => setState(() => _showCustomInput = true),
                icon: const Icon(Icons.edit, size: 16),
                label: const Text('自定义回应'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildTriggerCard(PetController controller, ThemeData theme) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => controller.generateRandomEvent(),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 20),
          child: Column(
            children: [
              Icon(
                Icons.auto_awesome,
                size: 40,
                color: theme.colorScheme.primary.withAlpha(100),
              ),
              const SizedBox(height: 12),
              Text(
                '点击触发随机事件',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: Colors.grey[600],
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '与小宠互动，共同成长',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: Colors.grey[400],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _respond(String option) {
    ref.read(petProvider).respondToEvent(option);
    setState(() {
      _showCustomInput = false;
      _customCtrl.clear();
    });
  }

  void _submitCustomResponse() {
    final text = _customCtrl.text.trim();
    if (text.isNotEmpty) {
      ref.read(petProvider).respondToEvent(text);
      setState(() {
        _showCustomInput = false;
        _customCtrl.clear();
      });
    }
  }

  Color _categoryColor(EventCategory category) {
    switch (category) {
      case EventCategory.daily:
        return const Color(0xFF2196F3);
      case EventCategory.fun:
        return const Color(0xFFFF9800);
      case EventCategory.challenge:
        return const Color(0xFFF44336);
      case EventCategory.healing:
        return const Color(0xFF4CAF50);
    }
  }
}
