/// lib/services/api_service.dart
/// DeepSeek API 网络请求封装 — 基于 Dio 实现流式长连接请求

import 'dart:convert';
import 'dart:async';
import 'package:dio/dio.dart';

class ApiService {
  static const _baseUrl = 'https://api.deepseek.com/chat/completions';
  final Dio _dio;

  ApiService()
    : _dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 30),
          receiveTimeout: const Duration(minutes: 5), // 流式可能持续较久
          responseType: ResponseType.stream,
        ),
      );

  /// 非流式请求：返回完整响应 JSON
  /// [apiKey] 鉴权密钥
  /// [apiParams] DeepSeek 接口参数（不含 messages）
  /// [messages] 消息列表
  /// [cancelToken] 可选取消令牌
  /// 返回 API 完整响应 JSON，失败抛异常
  Future<Map<String, dynamic>> chat({
    required String apiKey,
    required Map<String, dynamic> apiParams,
    required List<Map<String, dynamic>> messages,
    CancelToken? cancelToken,
  }) async {
    final body = Map<String, dynamic>.from(apiParams);
    body['messages'] = messages;
    body['stream'] = false;

    try {
      final response = await _dio.post(
        _baseUrl,
        data: jsonEncode(body),
        options: Options(
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
          },
          responseType: ResponseType.json,
        ),
        cancelToken: cancelToken,
      );

      return response.data as Map<String, dynamic>;
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        return {'choices': []};
      }
      throw Exception(_parseError(e));
    } catch (e) {
      throw Exception('AI 请求异常：$e');
    }
  }

  /// 流式对话请求
  /// [apiKey] 鉴权密钥
  /// [apiParams] DeepSeek 接口参数（不含 messages）
  /// [messages] 裁剪后的上下文消息列表
  /// [onChunk] 每收到一个数据分片时回调
  /// [onDone] 流正常结束时回调
  /// 流式/非流式统一入口
  /// [cancelToken] 传入后可由外部取消请求（中断输出）
  Future<void> streamChat({
    required String apiKey,
    required Map<String, dynamic> apiParams,
    required List<Map<String, dynamic>> messages,
    required Function(Map<String, dynamic> chunk) onChunk,
    required void Function() onDone,
    required Function(String error) onError,
    CancelToken? cancelToken,
    List<Map<String, dynamic>>? tools,
  }) async {
    final body = Map<String, dynamic>.from(apiParams);
    body['messages'] = messages;
    if (tools != null && tools.isNotEmpty) {
      body['tools'] = tools;
    }
    // 统一打开 usage：面板要显示上下文占用与缓存命中率。
    // 部分调用方（写作功能）自带 apiParams，这里补一层兜底。
    if (body['stream'] == true && body['stream_options'] == null) {
      body['stream_options'] = {'include_usage': true};
    }

    final isStream = apiParams['stream'] == true;

    if (isStream) {
      await _sendStream(body, apiKey, onChunk, onDone, onError, cancelToken);
    } else {
      await _sendNonStream(body, apiKey, onChunk, onDone, onError, cancelToken);
    }
  }

  /// SSE 流式请求
  Future<void> _sendStream(
    Map<String, dynamic> body,
    String apiKey,
    Function(Map<String, dynamic> chunk) onChunk,
    void Function() onDone,
    Function(String error) onError,
    CancelToken? cancelToken,
  ) async {
    try {
      final response = await _dio.post(
        _baseUrl,
        data: jsonEncode(body),
        options: Options(
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
            'Accept': 'text/event-stream',
          },
          responseType: ResponseType.stream,
        ),
        cancelToken: cancelToken,
      );

      final stream = response.data.stream as Stream<List<int>>;
      final buffer = StringBuffer();

      // 用流式解码器逐段解码：多字节字符（中文/emoji）被 TCP 分片切开时，
      // 解码器会自动拼完整，避免 utf8.decode(chunk) 抛 Unfinished UTF-8 异常
      await for (final textChunk in utf8.decoder.bind(stream)) {
        // 检查是否被外部取消
        if (cancelToken != null && cancelToken.isCancelled) {
          onDone();
          return;
        }

        buffer.write(textChunk);

        final text = buffer.toString();
        final lines = text.split('\n');
        final lastPart = lines.removeLast();

        for (final line in lines) {
          final trimmed = line.trim();
          if (trimmed.isEmpty || !trimmed.startsWith('data: ')) continue;

          final data = trimmed.substring(6);
          if (data == '[DONE]') {
            onDone();
            return;
          }

          try {
            final json = jsonDecode(data) as Map<String, dynamic>;
            onChunk(json);
          } catch (_) {}
        }

        buffer.clear();
        buffer.write(lastPart);
      }

      onDone();
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        onDone(); // 主动取消，保留已收到的部分内容
        return;
      }
      onError(_parseError(e));
    } catch (e) {
      onError(e.toString());
    }
  }

  /// 非流式请求：返回完整 JSON，转为 chunk 格式统一处理
  Future<void> _sendNonStream(
    Map<String, dynamic> body,
    String apiKey,
    Function(Map<String, dynamic> chunk) onChunk,
    void Function() onDone,
    Function(String error) onError,
    CancelToken? cancelToken,
  ) async {
    try {
      final response = await _dio.post(
        _baseUrl,
        data: jsonEncode(body),
        options: Options(
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
          },
          responseType: ResponseType.json,
        ),
        cancelToken: cancelToken,
      );

      final data = response.data as Map<String, dynamic>;
      // 非流式返回 message，转为 delta 格式统一交给 onChunk 处理
      final choices = data['choices'] as List?;
      if (choices != null && choices.isNotEmpty) {
        final choice = choices[0] as Map<String, dynamic>;
        final msg = choice['message'] as Map<String, dynamic>?;
        if (msg != null) {
          onChunk({
            'choices': [
              {'delta': msg, 'finish_reason': choice['finish_reason']},
            ],
            if (data['usage'] != null) 'usage': data['usage'],
          });
        }
      }
      onDone();
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        onDone();
        return;
      }
      onError(_parseError(e));
    } catch (e) {
      onError(e.toString());
    }
  }

  /// 解析网络异常为友好提示
  String _parseError(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
        return '连接超时，请检查网络';
      case DioExceptionType.receiveTimeout:
        return '响应超时，请稍后重试';
      case DioExceptionType.badResponse:
        final code = e.response?.statusCode;
        final body = e.response?.data;
        // 尝试提取 API 返回的错误详情
        String detail = '';
        if (body is String && body.isNotEmpty) {
          try {
            final errJson = jsonDecode(body) as Map<String, dynamic>;
            detail = errJson['error']?['message'] ?? body;
          } catch (_) {
            detail = body.length > 100 ? '${body.substring(0, 100)}...' : body;
          }
        }
        if (code == 401) return 'API Key 无效，请检查设置';
        if (code == 429) return '请求过于频繁，请稍后重试';
        return detail.isNotEmpty ? detail : '服务器错误 ($code)';
      default:
        return '网络异常：${e.message}';
    }
  }
}
