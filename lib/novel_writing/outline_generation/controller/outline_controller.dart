import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:deepseekapp/services/api_service.dart';
import 'package:deepseekapp/services/user_setting_service.dart';
import '../model/outline_setting.dart';
import '../model/outline_record.dart';
import '../model/db/outline_db_helper.dart';
import '../model/db/outline_record_db_helper.dart';

/// 大纲生成控制器，管理业务逻辑与状态
class OutlineController extends ChangeNotifier {
  final genreController = TextEditingController(text: '玄幻');
  final themeController = TextEditingController();
  final protagonistController = TextEditingController();
  final worldViewController = TextEditingController();
  final scrollController = ScrollController();
  final _apiService = ApiService();

  int majorEventCount = 5;
  int minorEventCount = 3;
  bool loading = false;
  String? error;
  String rawText = '';
  String title = '';
  CancelToken? _cancelToken;

  /// 取消当前生成
  void cancel() {
    _cancelToken?.cancel();
    _cancelToken = null;
    loading = false;
    notifyListeners();
  }

  void dispose() {
    genreController.dispose();
    themeController.dispose();
    protagonistController.dispose();
    worldViewController.dispose();
    scrollController.dispose();
    super.dispose();
  }

  void scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (scrollController.hasClients) {
        scrollController.animateTo(
          scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 50),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> generate() async {
    if (themeController.text.trim().isEmpty ||
        protagonistController.text.trim().isEmpty) {
      error = '请填写主题和主角设定';
      notifyListeners();
      return;
    }

    loading = true;
    error = null;
    rawText = '';
    title = '';
    notifyListeners();

    try {
      final global = await UserSettingService.getSettings();
      if (global.apiKey.isEmpty) {
        error = '请先在设置中填写 API Key';
        loading = false;
        notifyListeners();
        return;
      }

      // 读取专属大纲设置，找不到时使用默认值
      OutlineSetting outlineSetting = const OutlineSetting();
      try {
        final row = await OutlineDbHelper().getSettings();
        if (row != null) outlineSetting = OutlineSetting.fromMap(row);
      } catch (_) {}

      final systemPrompt = outlineSetting.systemPrompt.isNotEmpty
          ? outlineSetting.systemPrompt
          : '你是一个专业的小说大纲生成助手，请用纯文本格式输出。';

      final prompt =
          '''
你是从业十年资深网文/出版双栖小说编辑，擅长搭建逻辑闭环、人物成长清晰、伏笔回收完整的长篇小说大纲，严格遵守所有输出格式与内容约束，禁止擅自增删层级、改格式、加多余符号。

基础设定参数：
小说类型：${genreController.text}
核心主题：${themeController.text}
主角完整人设：${protagonistController.text}（包含身份、初始性格、执念、软肋、终极渴望、初始缺陷）
完整世界观：${worldViewController.text}（规则、势力、矛盾根源、危险机制、底层冲突）
全篇主事件总数量：$majorEventCount
单个主事件配套小事件固定数量：$minorEventCount

硬性内容创作规则（必须全部执行）：
1. 三幕均衡分配主事件：
   第一幕开端占总主事件30%，第二幕发展占总主事件50%，第三幕高潮结局占总主事件20%，无法整除时第二幕多分配余量；
2. 人物成长强制落地：每一幕结尾写明主角阶段性性格变化，全篇完成「缺陷暴露→挣扎蜕变→圆满/遗憾闭环」完整人物弧光；
3. 冲突分层：每个大事件必须包含外部矛盾+主角内心矛盾，至少埋1处长线伏笔；第三幕必须回收前文80%以上伏笔；
4. 情节节奏：小事件有递进关系，依次完成铺垫→冲突升级→危机加剧，禁止平铺流水账；
5. 结局区分两种导向：主题正向则圆满救赎结局，主题偏现实/暗黑则留白遗憾结局，全程贴合核心主题；
6. 禁忌约束：不出现逻辑漏洞、战力/世界观崩坏、人物行为动机割裂、强行降智、突兀机械降神。

固定输出格式（一字不差遵守，禁止markdown、表格、json、加粗符号，纯普通文本）：
1. 第一行固定格式：书名：《xxx》，书名贴合类型、主题、主角核心宿命，简洁有记忆点；
2. 第二行为空行；
3. 第三行核心概念简介，严格控制${outlineSetting.conceptMinWords}-${outlineSetting.conceptMaxWords}字，概括世界观、主角核心困境、故事最终落点；
4. 分段结构标识：
══ 第一幕：开端 ══
（分配好的开端主事件）
══ 第二幕：发展 ══
（分配好的发展主事件）
══ 第三幕：高潮&结局 ══
（分配好的高潮结局主事件）

单一大事件统一格式：
══ 大事件X：大事件标题 ══
大事件概述（${outlineSetting.majorEventMinWords}-${outlineSetting.majorEventMaxWords}字，写清本阶段核心危机、主角行动、埋下的长线伏笔）
○ 小事件1：小标题
小事件概要（${outlineSetting.minorEventMinWords}-${outlineSetting.minorEventMaxWords}字，写清场景、冲突、主角心理变化）
○ 小事件2：小标题
小事件概要（${outlineSetting.minorEventMinWords}-${outlineSetting.minorEventMaxWords}字，承接上一小事件，冲突升级，加深主角困境）
……循环至$minorEventCount个小事件
''';

      String accumulated = '';

      _cancelToken = CancelToken();

      await _apiService.streamChat(
        apiKey: global.apiKey,
        apiParams: {
          'model': outlineSetting.model,
          'temperature': outlineSetting.temperature,
          'max_tokens': outlineSetting.maxTokens,
          'stream': true,
        },
        messages: [
          {'role': 'system', 'content': systemPrompt},
          {'role': 'user', 'content': prompt},
        ],
        cancelToken: _cancelToken,
        onChunk: (chunk) {
          final choices = chunk['choices'] as List?;
          if (choices == null || choices.isEmpty) return;

          final delta = choices[0]['delta'] as Map<String, dynamic>?;
          if (delta == null) return;

          final content = delta['content'] as String?;
          if (content == null || content.isEmpty) return;

          accumulated += content;
          rawText = accumulated;
          if (title.isEmpty) {
            final firstLine = accumulated
                .split('\n')
                .firstWhere((l) => l.contains('书名：'), orElse: () => '');
            if (firstLine.isNotEmpty) {
              title = firstLine
                  .replaceAll(RegExp(r'^(书名：|《|》|\s)*'), '')
                  .trim();
            }
          }
          notifyListeners();
          scrollToBottom();
        },
        onDone: () {
          _cancelToken = null;
          // 自动保存到历史记录
          if (rawText.isNotEmpty) {
            final record = OutlineRecord(
              title: title,
              genre: genreController.text,
              theme: themeController.text,
              protagonist: protagonistController.text,
              worldview: worldViewController.text,
              content: rawText,
            );
            OutlineRecordDbHelper().insert(record.toMap());
          }
          loading = false;
          notifyListeners();
        },
        onError: (errorMsg) {
          _cancelToken = null;
          error = errorMsg;
          loading = false;
          notifyListeners();
        },
      );
    } catch (e) {
      error = e.toString().replaceFirst('Exception: ', '');
      loading = false;
      notifyListeners();
    }
  }
}
