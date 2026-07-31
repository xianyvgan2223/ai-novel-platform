import 'dart:isolate';

/// Isolate后台任务封装，用于执行耗时的AI生成任务
class CopyIsolateTask {
  /// 在后台Isolate中启动任务
  /// [params] 任务参数Map
  /// [sendPort] 用于向主Isolate发送结果的SendPort
  static void startTask(Map<String, dynamic> params, SendPort sendPort) {
    try {
      // 执行耗时任务
      final result = _executeTask(params);
      sendPort.send({'success': true, 'data': result});
    } catch (e) {
      sendPort.send({'success': false, 'error': e.toString()});
    }
  }

  /// 执行具体的后台任务逻辑
  static Map<String, dynamic> _executeTask(Map<String, dynamic> params) {
    final taskType = params['taskType'] as String?;

    switch (taskType) {
      case 'generateTotalStory':
        return _generateTotalStory(params);
      case 'generateCharacterStories':
        return _generateCharacterStories(params);
      default:
        throw Exception('未知的任务类型: $taskType');
    }
  }

  /// 生成副本总故事
  static Map<String, dynamic> _generateTotalStory(Map<String, dynamic> params) {
    // 模拟耗时计算
    // 实际AI请求会在主Isolate中通过CopyAiService完成
    return {'result': 'total_story_generated', 'copyId': params['copyId']};
  }

  /// 生成角色故事
  static Map<String, dynamic> _generateCharacterStories(
    Map<String, dynamic> params,
  ) {
    return {
      'result': 'character_stories_generated',
      'copyId': params['copyId'],
      'characterIds': params['characterIds'],
    };
  }

  /// 便捷方法：在Isolate中运行任务并获取结果
  static Future<Map<String, dynamic>> runTask(
    Map<String, dynamic> params,
  ) async {
    final receivePort = ReceivePort();
    await Isolate.spawn((sendPort) {
      startTask(params, sendPort);
    }, receivePort.sendPort);

    final result = await receivePort.first as Map<String, dynamic>;
    receivePort.close();
    return result;
  }
}
