import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';

/// AI基础HTTP客户端，封装POST请求
class AiBaseClient {
  final Dio _dio;

  AiBaseClient({Duration? connectTimeout, Duration? receiveTimeout})
      : _dio = Dio(BaseOptions(
          connectTimeout: connectTimeout ?? const Duration(seconds: 30),
          receiveTimeout: receiveTimeout ?? const Duration(seconds: 60),
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
        ));

  /// 发送HTTP POST请求
  /// [url] 目标URL
  /// [body] 请求体（Map形式）
  /// [headers] 可选的额外请求头
  /// [timeoutSeconds] 超时时间（秒）
  /// 返回响应体字符串，失败返回null
  Future<String?> sendRequest(
    String url,
    Map<String, dynamic> body, {
    Map<String, String>? headers,
    int timeoutSeconds = 30,
  }) async {
    try {
      final options = Options(
        sendTimeout: Duration(seconds: timeoutSeconds),
        receiveTimeout: Duration(seconds: timeoutSeconds),
        headers: headers,
      );

      final response = await _dio.post(
        url,
        data: body,
        options: options,
      );

      if (response.statusCode == 200) {
        return jsonEncode(response.data);
      }
      return null;
    } on DioException catch (e) {
      // 网络异常或超时
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        throw Exception('AI请求超时');
      } else if (e.type == DioExceptionType.connectionError) {
        throw Exception('网络连接失败');
      }
      throw Exception('AI请求失败: ${e.message}');
    } on SocketException {
      throw Exception('网络连接失败');
    } catch (e) {
      throw Exception('AI请求异常: $e');
    }
  }
}
