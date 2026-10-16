import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/foundation.dart';

import 'tts_engine.dart';

/// Web 端朗读引擎：直接用浏览器的 SpeechSynthesis（Web Speech API），
/// 不依赖任何第三方包。
///
/// 浏览器只在部分系统上装了中文语音；没有中文语音时按 [TtsSpeechRequest.language]
/// 设置 `utterance.lang`，由浏览器自行挑一个最接近的声音。真机上（Android）走的是
/// `tts_engine_io.dart` 的原生通道，本文件只在 Web 构建里参与编译。
TtsEngine createPlatformTtsEngine() => _WebTtsEngine();

/// 浏览器全局 `speechSynthesis`
JSObject? get _synth {
  final value = globalContext['speechSynthesis'];
  if (value == null || value.isUndefined || value.isNull) return null;
  return value as JSObject;
}

class _WebTtsEngine implements TtsEngine {
  bool _available = false;
  bool _speaking = false;
  String _error = '';
  VoidCallback? _onDone;
  void Function(String message)? _onError;

  /// 当前这一条对应的 utterance：stop 之后到达的 onend 要丢掉，
  /// 否则「停止播放」会被当成「这一段读完了」而自动读下一条。
  JSObject? _current;

  @override
  bool get isAvailable => _available;

  @override
  bool get isSpeaking => _speaking;

  @override
  String get errorMessage => _error;

  @override
  Future<bool> init({String language = 'zh-CN'}) async {
    _available = _synth != null;
    if (!_available) {
      _error = '当前浏览器不支持语音朗读（缺少 SpeechSynthesis）';
    }
    return _available;
  }

  @override
  Future<bool> speak(TtsSpeechRequest request) async {
    final text = request.text.trim();
    if (text.isEmpty) return false;
    final synth = _synth;
    if (synth == null) {
      _available = false;
      _error = '当前浏览器不支持语音朗读（缺少 SpeechSynthesis）';
      return false;
    }
    _available = true;
    try {
      synth.callMethod<JSAny?>('cancel'.toJS);
      final utterance = globalContext['SpeechSynthesisUtterance'] as JSFunction;
      final u = utterance.callAsConstructor<JSObject>(text.toJS);
      u.setProperty('lang'.toJS, request.language.toJS);
      u.setProperty('rate'.toJS, request.rate.toJS);
      u.setProperty('pitch'.toJS, request.pitch.toJS);
      u.setProperty(
        'onend'.toJS,
        (JSAny? _) {
          if (!identical(u, _current)) return;
          _current = null;
          _speaking = false;
          _onDone?.call();
        }.toJS,
      );
      u.setProperty(
        'onerror'.toJS,
        (JSAny? _) {
          if (!identical(u, _current)) return;
          _current = null;
          _speaking = false;
          _error = '浏览器朗读失败，请检查系统语音包';
          _onError?.call(_error);
        }.toJS,
      );
      _current = u;
      synth.callMethod<JSAny?>('speak'.toJS, u);
      _speaking = true;
      _error = '';
      return true;
    } catch (e) {
      _current = null;
      _speaking = false;
      _error = '浏览器朗读失败：$e';
      return false;
    }
  }

  @override
  Future<void> stop() async {
    _current = null;
    _speaking = false;
    final synth = _synth;
    if (synth == null) return;
    try {
      synth.callMethod<JSAny?>('cancel'.toJS);
    } catch (_) {
      // 取消失败不该打断界面
    }
  }

  @override
  void setCallbacks({
    required VoidCallback onDone,
    void Function(String message)? onError,
  }) {
    _onDone = onDone;
    _onError = onError;
  }

  @override
  Future<void> dispose() async {
    _onDone = null;
    _onError = null;
    await stop();
  }
}
