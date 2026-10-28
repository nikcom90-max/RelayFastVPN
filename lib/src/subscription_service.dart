import 'dart:convert';
import 'dart:io' show Platform;

import 'package:http/http.dart' as http;

import 'models.dart';
import 'xray_config.dart';

class SubscriptionException implements Exception {
  SubscriptionException(this.message);
  final String message;
  @override
  String toString() => message;
}

class SubscriptionResult {
  SubscriptionResult(this.body, this.info, this.remote, [this.variant = '']);

  /// Какой User-Agent сработал: '' (свой) или 'compat'.
  final String variant;
  final String body;
  final SubscriptionInfo info;

  /// null — заголовок `x-relayfast-config` не пришёл (оставляем прежний).
  final RemoteConfig? remote;
}

/// Скачивает подписку Remnawave.
///
/// Remnawave выбирает формат по User-Agent. Приложение понимает и base64-список
/// ссылок, и JSON-конфиги Xray (см. [variants]).
class SubscriptionService {
  SubscriptionService({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;

  /// Варианты User-Agent. Панель выбирает формат подписки по UA: для нашего
  /// собственного она отдаёт обычный список ссылок, а для Happ — JSON-конфиги
  /// Xray с балансировщиками и вашей маршрутизацией. Поэтому, если свой UA
  /// получил не JSON, пробуем совместимый. Лучше настроить в панели правило
  /// «UA начинается с RelayFastVPN → Xray JSON», тогда второй запрос не нужен.
  static const variants = ['', 'compat'];

  static String _userAgent(String variant, String appVersion) =>
      variant == 'compat' ? 'Happ/3.0.0' : 'RelayFastVPN/$appVersion';

  static bool _isJson(String body) {
    final t = body.trimLeft();
    return t.startsWith('[') || t.startsWith('{');
  }

  Future<SubscriptionResult> fetch(
    Uri url, {
    required String appVersion,
    required String hwid,
    String? osVersion,
    String? deviceModel,
    String? preferred,
  }) async {
    if (url.scheme != 'https' && url.scheme != 'http') {
      throw SubscriptionException('Ссылка должна начинаться с https://');
    }
    final order = [
      if (preferred != null) preferred,
      ...variants.where((v) => v != preferred),
    ];
    SubscriptionException? firstError;
    SubscriptionResult? fallback;
    for (final v in order) {
      try {
        final r = await _fetchOne(url, v,
            appVersion: appVersion,
            hwid: hwid,
            osVersion: osVersion,
            deviceModel: deviceModel);
        // Прошлый успешный вариант не перепроверяем; иначе ищем JSON.
        if (v == preferred || _isJson(r.body)) return r;
        fallback ??= r;
      } on SubscriptionException catch (e) {
        firstError ??= e;
      } catch (e) {
        // Неожиданный формат ответа — не роняем обновление целиком.
        firstError ??= SubscriptionException('Не удалось разобрать подписку: $e');
      }
    }
    if (fallback != null) return fallback;
    throw firstError ?? SubscriptionException('Не удалось получить подписку.');
  }

  Future<SubscriptionResult> _fetchOne(
    Uri url,
    String variant, {
    required String appVersion,
    required String hwid,
    String? osVersion,
    String? deviceModel,
  }) async {
    final http.Response r;
    try {
      r = await _client.get(url, headers: {
        'User-Agent': _userAgent(variant, appVersion),
        // HWID-лимит устройств Remnawave (если включён в панели).
        'x-hwid': hwid,
        'x-device-os': Platform.isWindows ? 'Windows' : 'Android',
        // Remnawave показывает это в карточке устройства.
        if (osVersion != null && osVersion.isNotEmpty) 'x-ver-os': osVersion,
        if (deviceModel != null && deviceModel.isNotEmpty)
          'x-device-model': deviceModel,
      }).timeout(const Duration(seconds: 25));
    } on Exception catch (e) {
      throw SubscriptionException('Не удалось связаться с сервером: $e');
    }

    if (r.statusCode == 404) {
      throw SubscriptionException('Подписка не найдена. Проверьте ссылку.');
    }
    if (r.statusCode == 403 || r.statusCode == 401) {
      throw SubscriptionException(
          'Доступ запрещён (возможно, достигнут лимит устройств).');
    }
    if (r.statusCode != 200) {
      throw SubscriptionException('Сервер ответил кодом ${r.statusCode}.');
    }

    final body = utf8.decode(r.bodyBytes, allowMalformed: true);
    if (SubscriptionParser.parse(body).isEmpty) {
      throw SubscriptionException(
          'В подписке не найдено ни одного поддерживаемого сервера. '
          'Возможно, она истекла или отключена.');
    }

    return SubscriptionResult(
      body,
      SubscriptionInfo.fromHeaders(r.headers),
      RemoteConfig.fromHeader(r.headers[RemoteConfig.headerName]),
      variant,
    );
  }
}
