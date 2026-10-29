import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../sync/application/sync_service.dart';

/// 应用内更新：检查版本 → 下载 APK → 校验 SHA-256 → 调起系统安装器。
///
/// 服务地址复用「设置 → 整库同步」里已保存的地址；没有配置时按现有解析链找一次。
class AppUpdateService {
  static const MethodChannel _channel = MethodChannel('deepseek_app/update');

  /// 当前安装包的 versionCode（Android 的升级判断依据）
  Future<int> currentVersionCode() async {
    _requireAndroid();
    try {
      return await _channel.invokeMethod<int>('versionCode') ?? 0;
    } on MissingPluginException {
      throw const AppUpdateException('当前平台不支持应用内更新');
    } on PlatformException catch (e) {
      throw AppUpdateException(e.message ?? '读取版本号失败');
    }
  }

  /// 检查服务端最新版本
  Future<AppUpdateInfo> check() async {
    _requireAndroid();
    final versionCode = await currentVersionCode();
    final baseUrl = await _resolveBaseUrl();
    final token = await SyncService.getToken();

    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 20),
    ));
    try {
      final response = await dio.get<dynamic>(
        '$baseUrl/api/app/latest',
        queryParameters: {
          'platform': 'android',
          'versionCode': versionCode,
        },
        options: Options(
          headers: token.isEmpty ? null : <String, String>{'x-api-token': token},
        ),
      );
      final body = response.data;
      if (body is! Map || body['ok'] != true) {
        throw AppUpdateException(_errorMessage(body) ?? '服务端返回异常');
      }
      final data = body['data'];
      if (data is! Map) {
        throw const AppUpdateException('服务端返回的数据格式不正确');
      }
      return AppUpdateInfo.fromJson(
        Map<String, dynamic>.from(data),
        currentVersionCode: versionCode,
      );
    } on DioException catch (e) {
      throw AppUpdateException(_describeDioError(e));
    }
  }

  /// 下载并调起安装。已经下载且哈希一致的 APK 会直接复用，方便授权后重试。
  Future<String> downloadAndInstall(
    AppUpdateInfo info, {
    void Function(int received, int total)? onProgress,
  }) async {
    _requireAndroid();
    final baseUrl = await _resolveBaseUrl();
    final token = await SyncService.getToken();

    final externalDir = await getExternalStorageDirectory();
    if (externalDir == null) {
      throw const AppUpdateException('无法访问应用存储目录');
    }
    final updateDir = Directory('${externalDir.path}/update');
    await updateDir.create(recursive: true);
    final file = File('${updateDir.path}/${info.fileName}');

    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(minutes: 10),
    ));

    if (!await _matchesHash(file, info.sha256)) {
      if (await file.exists()) {
        await file.delete();
      }
      try {
        await dio.download(
          '$baseUrl${info.downloadPath}',
          file.path,
          onReceiveProgress: onProgress,
          deleteOnError: true,
          options: Options(
            headers: token.isEmpty ? null : <String, String>{'x-api-token': token},
          ),
        );
      } on DioException catch (e) {
        throw AppUpdateException(_describeDioError(e));
      }
    }

    if (!await _matchesHash(file, info.sha256)) {
      await file.delete();
      throw const AppUpdateException('APK 校验失败，文件可能不完整，请重试');
    }

    if (!await canInstallPackages()) {
      await openInstallPermission();
      throw const AppUpdateException(
        '请先允许本应用「安装未知应用」，然后返回这里重试',
        needPermission: true,
      );
    }

    try {
      await _channel.invokeMethod<void>('installApk', {'path': file.path});
    } on PlatformException catch (e) {
      throw AppUpdateException(e.message ?? '调起安装失败');
    }
    return file.path;
  }

  /// App 启动时清理已经装上的更新包。
  ///
  /// 只删除磁盘上 APK 的 versionCode 小于等于当前已安装版本的包：
  /// - 更新成功后，下载的 APK 变成“旧包”，下次启动删掉；
  /// - 下载了但还没安装 / 安装被取消的包版本更高，保留，方便直接重试；
  /// - 损坏或读不出版本的包不动，避免误删。
  Future<void> cleanupInstalledUpdates() async {
    if (!Platform.isAndroid) return;
    try {
      final currentVersion = await currentVersionCode();
      final externalDir = await getExternalStorageDirectory();
      if (externalDir == null) return;
      final updateDir = Directory('${externalDir.path}/update');
      if (!await updateDir.exists()) return;

      await for (final entity in updateDir.list()) {
        if (entity is! File ||
            !entity.path.toLowerCase().endsWith('.apk')) {
          continue;
        }
        int apkVersion;
        try {
          apkVersion =
              await _channel.invokeMethod<int>(
                'apkVersionCode',
                <String, Object?>{'path': entity.path},
              ) ??
              -1;
        } on MissingPluginException {
          return;
        } on PlatformException catch (e) {
          debugPrint('[update] 读取 APK 版本失败：${entity.path} ${e.message}');
          continue;
        }
        if (apkVersion > 0 && apkVersion <= currentVersion) {
          try {
            await entity.delete();
            debugPrint('[update] 已清理已安装的更新包：${entity.path}');
          } catch (e) {
            debugPrint('[update] 删除更新包失败：${entity.path} $e');
          }
        }
      }
    } catch (e) {
      debugPrint('[update] 清理更新包失败：$e');
    }
  }

  Future<bool> canInstallPackages() async {
    _requireAndroid();
    try {
      return await _channel.invokeMethod<bool>('canInstallPackages') ?? true;
    } on MissingPluginException {
      return false;
    }
  }

  Future<void> openInstallPermission() async {
    _requireAndroid();
    try {
      await _channel.invokeMethod<void>('openInstallPermission');
    } on PlatformException catch (e) {
      throw AppUpdateException(e.message ?? '打不开安装权限设置');
    }
  }

  Future<String> _resolveBaseUrl() async {
    var baseUrl = await SyncService.getBaseUrl();
    if (baseUrl.isEmpty) {
      final resolved = await SyncService.resolveAddress(allowScan: false);
      baseUrl = resolved?.baseUrl ?? '';
    }
    baseUrl = baseUrl.replaceAll(RegExp(r'/+$'), '');
    if (baseUrl.isEmpty) {
      throw const AppUpdateException('请先在「设置 → 整库同步」里连接电脑');
    }
    return baseUrl;
  }

  Future<bool> _matchesHash(File file, String expected) async {
    if (!await file.exists()) return false;
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString().toLowerCase() == expected.toLowerCase();
  }

  void _requireAndroid() {
    if (!Platform.isAndroid) {
      throw const AppUpdateException('应用内更新目前仅支持 Android');
    }
  }

  String _describeDioError(DioException error) {
    final data = error.response?.data;
    final message = _errorMessage(data);
    if (message != null && message.isNotEmpty) return message;
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return '连接电脑超时，请检查手机与电脑是否在同一局域网';
      case DioExceptionType.connectionError:
        return '连不上电脑同步服务，请检查地址、USB 隧道或防火墙';
      default:
        return '请求电脑失败：${error.message ?? error.type.name}';
    }
  }

  String? _errorMessage(Object? body) {
    if (body is Map && body['error'] != null) {
      return body['error'].toString();
    }
    return null;
  }
}

class AppUpdateInfo {
  final int versionCode;
  final String versionName;
  final String fileName;
  final int size;
  final String sha256;
  final String downloadPath;
  final bool force;
  final String changelog;
  final bool hasUpdate;
  final int currentVersionCode;

  const AppUpdateInfo({
    required this.versionCode,
    required this.versionName,
    required this.fileName,
    required this.size,
    required this.sha256,
    required this.downloadPath,
    required this.force,
    required this.changelog,
    required this.hasUpdate,
    required this.currentVersionCode,
  });

  factory AppUpdateInfo.fromJson(Map<String, dynamic> json, {required int currentVersionCode}) {
    return AppUpdateInfo(
      versionCode: (json['versionCode'] as num?)?.toInt() ?? 0,
      versionName: (json['versionName'] ?? '').toString(),
      fileName: (json['fileName'] ?? '').toString(),
      size: (json['size'] as num?)?.toInt() ?? 0,
      sha256: (json['sha256'] ?? '').toString(),
      downloadPath: (json['downloadPath'] ?? '').toString(),
      force: json['force'] == true,
      changelog: (json['changelog'] ?? '').toString(),
      hasUpdate: json['hasUpdate'] == true,
      currentVersionCode: currentVersionCode,
    );
  }

  String get sizeText {
    if (size <= 0) return '-';
    return '${(size / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}

class AppUpdateException implements Exception {
  final String message;
  final bool needPermission;

  const AppUpdateException(this.message, {this.needPermission = false});

  @override
  String toString() => message;
}
