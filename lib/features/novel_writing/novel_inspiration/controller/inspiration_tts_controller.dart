import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../outline_listening/service/hybrid_tts_engine.dart';
import '../../outline_listening/service/tts_engine.dart';

/// 小说灵感的「听读」控制器。
///
/// - DeepSeek：引擎内部按句分段，并在播放当前段时预取下一段。
/// - 本地/系统 TTS：Dart 侧先切成短句再逐段调用，避免部分系统引擎
///   对超长文本直接拒绝；同时避免把整篇推演一次性丢给本地模型。
class InspirationTtsController extends ChangeNotifier {
  InspirationTtsController({HybridTtsEngine? engine})
    : _engine = engine ?? HybridTtsEngine() {
    _engine.setCallbacks(
      onDone: _handleDone,
      onError: _handleError,
    );
  }

  final HybridTtsEngine _engine;

  bool speaking = false;
  int? speakingBranchId;
  String error = '';

  int _runId = 0;
  List<String> _chunks = const [];
  int _chunkIndex = 0;
  double _rate = 1.0;
  bool _expectingDone = false;

  bool isSpeakingBranch(int branchId) =>
      speaking && speakingBranchId == branchId;

  Future<List<TtsEngineOption>> availableEngines() =>
      _engine.availableEngines();

  Future<void> selectEngine(String engineId) => _engine.selectEngine(engineId);

  Future<void> speak({
    required int branchId,
    required String text,
    required String engineId,
    required double rate,
  }) async {
    final clean = text.trim();
    if (clean.isEmpty) return;

    final run = ++_runId;
    _expectingDone = false;
    await _engine.stop();
    if (run != _runId) return;
    await _engine.selectEngine(engineId);
    if (run != _runId) return;

    error = '';
    _rate = rate.clamp(0.75, 4.0);
    _chunks = engineId.startsWith(HybridTtsEngine.deepSeekPrefix)
        ? [clean]
        : _splitText(clean, maxChars: 100);
    _chunkIndex = 0;
    speaking = true;
    speakingBranchId = branchId;
    notifyListeners();
    await _speakChunk(run);
  }

  Future<void> _speakChunk(int run) async {
    if (run != _runId || !speaking) return;
    final started = await _engine.speak(
      TtsSpeechRequest(text: _chunks[_chunkIndex], rate: _rate),
    );
    if (run != _runId) return;
    if (!started) {
      _fail(
        _engine.errorMessage.isNotEmpty ? _engine.errorMessage : '朗读没能开始',
      );
      return;
    }
    _expectingDone = true;
  }

  void _handleDone() {
    if (!speaking || !_expectingDone) return;
    _expectingDone = false;
    if (_chunkIndex + 1 < _chunks.length) {
      _chunkIndex++;
      unawaited(_speakChunk(_runId));
      return;
    }
    speaking = false;
    speakingBranchId = null;
    notifyListeners();
  }

  void _handleError(String message) {
    if (!speaking) return;
    _fail(message);
  }

  void _fail(String message) {
    _expectingDone = false;
    _chunks = const [];
    speaking = false;
    speakingBranchId = null;
    error = message;
    notifyListeners();
  }

  Future<void> stop() async {
    _runId++;
    _chunks = const [];
    _chunkIndex = 0;
    _expectingDone = false;
    speaking = false;
    speakingBranchId = null;
    await _engine.stop();
    notifyListeners();
  }

  Future<void> toggle({
    required int branchId,
    required String text,
    required String engineId,
    required double rate,
  }) async {
    if (isSpeakingBranch(branchId)) {
      await stop();
      return;
    }
    await speak(
      branchId: branchId,
      text: text,
      engineId: engineId,
      rate: rate,
    );
  }

  List<String> _splitText(String text, {required int maxChars}) {
    final out = <String>[];
    var rest = text;
    const enders = ['。', '！', '？', '；', '\n', '.', '!', '?', ';'];
    while (rest.length > maxChars) {
      var cut = maxChars;
      for (final p in enders) {
        final i = rest.lastIndexOf(p, maxChars);
        if (i > maxChars ~/ 2) {
          cut = i + 1;
          break;
        }
      }
      final piece = rest.substring(0, cut).trim();
      if (piece.isNotEmpty) out.add(piece);
      rest = rest.substring(cut).trim();
    }
    if (rest.isNotEmpty) out.add(rest);
    return out;
  }

  @override
  void dispose() {
    _runId++;
    _expectingDone = false;
    _engine.dispose();
    super.dispose();
  }
}
