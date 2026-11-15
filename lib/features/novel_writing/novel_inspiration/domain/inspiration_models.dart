// 小说灵感 — 数据模型
//
// 与其它小说功能的数据完全隔离：会话、推演、人物卡都只属于本功能；
// 世界观 / 主题也保存在本功能的会话记录里，不写 outline_records。

import 'dart:convert';

/// 小说灵感设置（独立于大纲生成 / 小事件详写设置）
class InspirationSettings {
  final String model;
  final double temperature;
  final int maxTokens;
  final String systemPrompt;
  final bool enableThinking;

  /// 思考强度：none / low / high / max（仅开启思考时生效）
  final String reasoningEffort;

  /// DeepSeek TTS 音色：stella / tide（旧字段，保留以兼容旧数据）
  final String ttsVoice;

  /// 朗读引擎：auto（系统优先，本地兜底）/ builtin（本地离线）/ deepseek:stella / deepseek:tide
  final String ttsEngineId;

  /// 朗读语速（0.75 ~ 4.0）
  final double ttsRate;

  /// 是否显示「回到底部」按钮（只在未到底时显示）
  final bool showScrollToBottom;

  /// 一次请求并行生成多少个推演（默认 3）
  final int concurrency;

  const InspirationSettings({
    this.model = 'deepseek-flash',
    this.temperature = 0.8,
    this.maxTokens = 4096,
    this.systemPrompt = '',
    this.enableThinking = true,
    this.reasoningEffort = 'high',
    this.ttsVoice = 'stella',
    this.ttsEngineId = 'auto',
    this.ttsRate = 1.0,
    this.showScrollToBottom = true,
    this.concurrency = 3,
  });

  InspirationSettings copyWith({
    String? model,
    double? temperature,
    int? maxTokens,
    String? systemPrompt,
    bool? enableThinking,
    String? reasoningEffort,
    String? ttsVoice,
    String? ttsEngineId,
    double? ttsRate,
    bool? showScrollToBottom,
    int? concurrency,
  }) => InspirationSettings(
    model: model ?? this.model,
    temperature: temperature ?? this.temperature,
    maxTokens: maxTokens ?? this.maxTokens,
    systemPrompt: systemPrompt ?? this.systemPrompt,
    enableThinking: enableThinking ?? this.enableThinking,
    reasoningEffort: reasoningEffort ?? this.reasoningEffort,
    ttsVoice: ttsVoice ?? this.ttsVoice,
    ttsEngineId: ttsEngineId ?? this.ttsEngineId,
    ttsRate: ttsRate ?? this.ttsRate,
    showScrollToBottom: showScrollToBottom ?? this.showScrollToBottom,
    concurrency: concurrency ?? this.concurrency,
  );

  Map<String, dynamic> toMap() => {
    'model': model,
    'temperature': temperature,
    'max_tokens': maxTokens,
    'system_prompt': systemPrompt,
    'enable_thinking': enableThinking ? 1 : 0,
    'reasoning_effort': reasoningEffort,
    'tts_voice': ttsVoice,
    'tts_engine': ttsEngineId,
    'tts_rate': ttsRate,
    'show_scroll_to_bottom': showScrollToBottom ? 1 : 0,
    'concurrency': concurrency,
  };

  factory InspirationSettings.fromMap(Map<String, dynamic> map) =>
      InspirationSettings(
        model: map['model'] as String? ?? 'deepseek-flash',
        temperature: (map['temperature'] as num?)?.toDouble() ?? 0.8,
        maxTokens: map['max_tokens'] as int? ?? 4096,
        systemPrompt: map['system_prompt'] as String? ?? '',
        enableThinking:
            map['enable_thinking'] == null ||
            (map['enable_thinking'] as int?) == 1,
        reasoningEffort: map['reasoning_effort'] as String? ?? 'high',
        ttsVoice: map['tts_voice'] as String? ?? 'stella',
        ttsEngineId: map['tts_engine'] as String? ?? 'auto',
        ttsRate: ((map['tts_rate'] as num?)?.toDouble() ?? 1.0).clamp(
          0.75,
          4.0,
        ),
        showScrollToBottom: map['show_scroll_to_bottom'] == null ||
            (map['show_scroll_to_bottom'] as int?) == 1,
        concurrency: ((map['concurrency'] as int?) ?? 3).clamp(1, 10),
      );
}

/// 导入到「小说灵感」的大 / 小事件（只是快照，不回写大纲）
class InspirationOutlineEvent {
  final int? chapterId;
  final String type; // 'major' | 'minor'
  final String title;
  final String summary;
  final int? majorNumber;
  final int? minorNumber;

  const InspirationOutlineEvent({
    this.chapterId,
    required this.type,
    required this.title,
    required this.summary,
    this.majorNumber,
    this.minorNumber,
  });

  bool get isMajor => type == 'major';

  Map<String, dynamic> toMap() => {
    'chapterId': chapterId,
    'type': type,
    'title': title,
    'summary': summary,
    'majorNumber': majorNumber,
    'minorNumber': minorNumber,
  };

  factory InspirationOutlineEvent.fromMap(Map<String, dynamic> map) =>
      InspirationOutlineEvent(
        chapterId: map['chapterId'] as int?,
        type: map['type'] as String? ?? 'minor',
        title: map['title'] as String? ?? '',
        summary: map['summary'] as String? ?? '',
        majorNumber: map['majorNumber'] as int?,
        minorNumber: map['minorNumber'] as int?,
      );

  static List<InspirationOutlineEvent> decodeList(String raw) {
    try {
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      return list
          .whereType<Map<String, dynamic>>()
          .map(InspirationOutlineEvent.fromMap)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static String encodeList(List<InspirationOutlineEvent> events) =>
      jsonEncode(events.map((e) => e.toMap()).toList());
}

/// 一次灵感会话（左侧历史记录里的一项）
class InspirationSession {
  final int? id;
  final String title;
  final String worldView;
  final String theme;
  final int? outlineRecordId;
  final String outlineTitle;
  final List<InspirationOutlineEvent> events;
  final String createdAt;
  final String updatedAt;

  const InspirationSession({
    this.id,
    this.title = '',
    this.worldView = '',
    this.theme = '',
    this.outlineRecordId,
    this.outlineTitle = '',
    this.events = const [],
    this.createdAt = '',
    this.updatedAt = '',
  });

  bool get hasOutline => outlineRecordId != null && outlineTitle.isNotEmpty;

  InspirationSession copyWith({
    int? id,
    String? title,
    String? worldView,
    String? theme,
    int? outlineRecordId,
    String? outlineTitle,
    List<InspirationOutlineEvent>? events,
    String? createdAt,
    String? updatedAt,
    bool clearOutline = false,
  }) => InspirationSession(
    id: id ?? this.id,
    title: title ?? this.title,
    worldView: worldView ?? this.worldView,
    theme: theme ?? this.theme,
    outlineRecordId: clearOutline
        ? null
        : (outlineRecordId ?? this.outlineRecordId),
    outlineTitle: clearOutline ? '' : (outlineTitle ?? this.outlineTitle),
    events: clearOutline ? const [] : (events ?? this.events),
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, dynamic> toMap() => {
    'title': title,
    'world_view': worldView,
    'theme': theme,
    'outline_record_id': outlineRecordId,
    'outline_title': outlineTitle,
    'selected_events': InspirationOutlineEvent.encodeList(events),
    'created_at': createdAt,
    'updated_at': updatedAt,
  };

  factory InspirationSession.fromMap(Map<String, dynamic> map) =>
      InspirationSession(
        id: map['id'] as int?,
        title: map['title'] as String? ?? '',
        worldView: map['world_view'] as String? ?? '',
        theme: map['theme'] as String? ?? '',
        outlineRecordId: map['outline_record_id'] as int?,
        outlineTitle: map['outline_title'] as String? ?? '',
        events: InspirationOutlineEvent.decodeList(
          map['selected_events'] as String? ?? '[]',
        ),
        createdAt: map['created_at'] as String? ?? '',
        updatedAt: map['updated_at'] as String? ?? '',
      );
}

/// 对话模式的一条消息（与推演模式完全分离）。
class InspirationChatMessage {
  final int? id;
  final int sessionId;
  final String role; // 'user' | 'assistant'
  final String content;
  final String createdAt;

  const InspirationChatMessage({
    this.id,
    required this.sessionId,
    required this.role,
    required this.content,
    this.createdAt = '',
  });

  bool get isUser => role == 'user';

  Map<String, dynamic> toMap() => {
    'session_id': sessionId,
    'role': role,
    'content': content,
    'created_at': createdAt,
    'updated_at': createdAt,
  };

  factory InspirationChatMessage.fromMap(Map<String, dynamic> map) =>
      InspirationChatMessage(
        id: map['id'] as int?,
        sessionId: map['session_id'] as int? ?? 0,
        role: map['role'] as String? ?? 'user',
        content: map['content'] as String? ?? '',
        createdAt: map['created_at'] as String? ?? '',
      );
}

/// 一个推演结果（AI 生成的一段完整情节正文）
class InspirationBranch {
  final int? id;
  final int sessionId;
  final int messageId;
  final String content;
  final String kind; // 'single' | 'merge'
  final bool chosen;
  final int generationNo;
  final List<int> sourceIds;
  final String createdAt;
  final String updatedAt;

  const InspirationBranch({
    this.id,
    required this.sessionId,
    required this.messageId,
    required this.content,
    this.kind = 'single',
    this.chosen = false,
    this.generationNo = 1,
    this.sourceIds = const [],
    this.createdAt = '',
    this.updatedAt = '',
  });

  bool get isMerge => kind == 'merge';

  InspirationBranch copyWith({
    int? id,
    String? content,
    String? kind,
    bool? chosen,
    int? generationNo,
    List<int>? sourceIds,
    String? updatedAt,
  }) => InspirationBranch(
    id: id ?? this.id,
    sessionId: sessionId,
    messageId: messageId,
    content: content ?? this.content,
    kind: kind ?? this.kind,
    chosen: chosen ?? this.chosen,
    generationNo: generationNo ?? this.generationNo,
    sourceIds: sourceIds ?? this.sourceIds,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, dynamic> toMap() => {
    'session_id': sessionId,
    'message_id': messageId,
    'content': content,
    'kind': kind,
    'chosen': chosen ? 1 : 0,
    'generation_no': generationNo,
    'source_ids': jsonEncode(sourceIds),
    'created_at': createdAt,
    'updated_at': updatedAt,
  };

  factory InspirationBranch.fromMap(Map<String, dynamic> map) {
    final rawSources = map['source_ids'] as String? ?? '[]';
    List<int> sources = const [];
    try {
      final list = jsonDecode(rawSources);
      if (list is List) sources = list.whereType<int>().toList();
    } catch (_) {}
    return InspirationBranch(
      id: map['id'] as int?,
      sessionId: map['session_id'] as int? ?? 0,
      messageId: map['message_id'] as int? ?? 0,
      content: map['content'] as String? ?? '',
      kind: map['kind'] as String? ?? 'single',
      chosen: (map['chosen'] as int? ?? 0) == 1,
      generationNo: map['generation_no'] as int? ?? 1,
      sourceIds: sources,
      createdAt: map['created_at'] as String? ?? '',
      updatedAt: map['updated_at'] as String? ?? '',
    );
  }
}

/// 一次「修改对话」前的快照：编辑前指令 + 当时的采用结果。
class InspirationMessageRevision {
  final String instruction;
  final String result;
  final String createdAt;

  const InspirationMessageRevision({
    required this.instruction,
    this.result = '',
    this.createdAt = '',
  });

  Map<String, dynamic> toMap() => {
    'instruction': instruction,
    'result': result,
    'created_at': createdAt,
  };

  factory InspirationMessageRevision.fromMap(Map<String, dynamic> map) =>
      InspirationMessageRevision(
        instruction: map['instruction'] as String? ?? '',
        result: map['result'] as String? ?? '',
        createdAt: map['created_at'] as String? ?? '',
      );

  static List<InspirationMessageRevision> decodeList(String raw) {
    try {
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      return list
          .whereType<Map<String, dynamic>>()
          .map(InspirationMessageRevision.fromMap)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static String encodeList(List<InspirationMessageRevision> revisions) =>
      jsonEncode(revisions.map((r) => r.toMap()).toList());
}

/// 一条用户指令 + 它下面的所有推演结果
class InspirationMessage {
  final int? id;
  final int sessionId;
  final String content;
  final String createdAt;
  final List<InspirationMessageRevision> revisions;
  final List<InspirationBranch> branches;

  const InspirationMessage({
    this.id,
    required this.sessionId,
    required this.content,
    this.createdAt = '',
    this.revisions = const [],
    this.branches = const [],
  });

  InspirationMessage copyWith({
    List<InspirationMessageRevision>? revisions,
    List<InspirationBranch>? branches,
  }) => InspirationMessage(
    id: id,
    sessionId: sessionId,
    content: content,
    createdAt: createdAt,
    revisions: revisions ?? this.revisions,
    branches: branches ?? this.branches,
  );

  InspirationBranch? get chosenBranch {
    for (final b in branches) {
      if (b.chosen) return b;
    }
    return null;
  }
}

/// 本功能专属的人物卡
class InspirationCharacterCard {
  final int? id;
  final int sessionId;
  final String name;
  final String description;
  final String personality;
  final String experiences;
  final String skills;
  final String status;
  final bool inject;
  final String createdAt;
  final String updatedAt;

  const InspirationCharacterCard({
    this.id,
    required this.sessionId,
    this.name = '',
    this.description = '',
    this.personality = '',
    this.experiences = '',
    this.skills = '',
    this.status = '',
    this.inject = true,
    this.createdAt = '',
    this.updatedAt = '',
  });

  bool get hasContent => name.trim().isNotEmpty;

  InspirationCharacterCard copyWith({
    int? id,
    String? name,
    String? description,
    String? personality,
    String? experiences,
    String? skills,
    String? status,
    bool? inject,
    String? updatedAt,
  }) => InspirationCharacterCard(
    id: id ?? this.id,
    sessionId: sessionId,
    name: name ?? this.name,
    description: description ?? this.description,
    personality: personality ?? this.personality,
    experiences: experiences ?? this.experiences,
    skills: skills ?? this.skills,
    status: status ?? this.status,
    inject: inject ?? this.inject,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, dynamic> toMap() => {
    'session_id': sessionId,
    'name': name,
    'description': description,
    'personality': personality,
    'experiences': experiences,
    'skills': skills,
    'status': status,
    'inject': inject ? 1 : 0,
    'created_at': createdAt,
    'updated_at': updatedAt,
  };

  factory InspirationCharacterCard.fromMap(Map<String, dynamic> map) =>
      InspirationCharacterCard(
        id: map['id'] as int?,
        sessionId: map['session_id'] as int? ?? 0,
        name: map['name'] as String? ?? '',
        description: map['description'] as String? ?? '',
        personality: map['personality'] as String? ?? '',
        experiences: map['experiences'] as String? ?? '',
        skills: map['skills'] as String? ?? '',
        status: map['status'] as String? ?? '',
        inject: (map['inject'] as int? ?? 1) == 1,
        createdAt: map['created_at'] as String? ?? '',
        updatedAt: map['updated_at'] as String? ?? '',
      );
}
