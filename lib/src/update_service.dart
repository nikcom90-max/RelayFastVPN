import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

/// Новая версия приложения.
class UpdateInfo {
  UpdateInfo(this.build, this.tag, this.apkUrl, this.size, this.notes);
  final int build;
  final String tag;
  final String apkUrl; // APK (Android) или установщик (Windows)
  final int size;
  final String notes;
}

/// Проверка и установка обновлений из GitHub Releases: Android (APK) и Windows
/// (установщик). Репозиторий должен быть открытым; его имя подставляет сборка
/// (`--dart-define=UPDATE_REPO=владелец/репозиторий`). Своих серверов не нужно.
class UpdateService {
  static const repo = String.fromEnvironment('UPDATE_REPO');
  static const _ch = MethodChannel('relayfast/vpn');

  static bool get enabled =>
      repo.isNotEmpty && (Platform.isAndroid || Platform.isWindows);

  /// Теги релизов: Android — build-N, Windows — windows-N (у них разные счётчики).
  static String get tagPrefix => Platform.isWindows ? 'windows-' : 'build-';

  /// ABI по номеру сборки: Flutter при --split-per-abi прибавляет 1000/2000/4000.
  static String abiFor(int rawBuild) {
    switch (rawBuild ~/ 1000) {
      case 1:
        return 'armeabi-v7a';
      case 4:
        return 'x86_64';
      default:
        return 'arm64-v8a';
    }
  }

  /// Номер сборки из тега вида «build-12» / «windows-7» с нужным префиксом.
  static int? buildOfTag(String tag, String prefix) {
    if (!tag.startsWith(prefix)) return null;
    return int.tryParse(tag.substring(prefix.length));
  }

  /// Самый новый релиз с нужным префиксом тега среди списка из API GitHub.
  static Map<String, dynamic>? pickRelease(List releases, String prefix) {
    Map<String, dynamic>? best;
    var bestN = -1;
    for (final r in releases) {
      if (r is! Map || r['draft'] == true || r['prerelease'] == true) continue;
      final n = buildOfTag('${r['tag_name']}', prefix);
      if (n != null && n > bestN) {
        bestN = n;
        best = Map<String, dynamic>.from(r);
      }
    }
    return best;
  }

  static String _assetName(int rawBuild) =>
      Platform.isWindows ? 'RelayFastVPN-Setup.exe' : 'RelayFastVPN-${abiFor(rawBuild)}.apk';

  /// Теги из ленты релизов (releases.atom): у неё нет лимитов запросов,
  /// в отличие от API (60 в час на адрес, а у мобильных операторов адрес общий).
  static List<String> tagsFromAtom(String xml) {
    final out = <String>[];
    for (final m in RegExp(r'/releases/tag/([^"<\s]+)').allMatches(xml)) {
      final t = Uri.decodeComponent(m.group(1)!);
      if (!out.contains(t)) out.add(t);
    }
    return out;
  }

  /// Самый новый тег с нужным префиксом или null.
  static String? newestTag(Iterable<String> tags, String prefix) {
    String? best;
    var bestN = -1;
    for (final t in tags) {
      final n = buildOfTag(t, prefix);
      if (n != null && n > bestN) {
        bestN = n;
        best = t;
      }
    }
    return best;
  }

  /// Новая версия на GitHub (новее [currentBuild]) или null.
  static Future<UpdateInfo?> check(int currentBuild, int rawBuild) async {
    if (!enabled) return null;
    final r = await http
        .get(Uri.parse('https://github.com/$repo/releases.atom'))
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) {
      throw Exception('GitHub ответил ${r.statusCode} (репозиторий должен быть открытым)');
    }
    final tag = newestTag(tagsFromAtom(utf8.decode(r.bodyBytes)), tagPrefix);
    if (tag == null) return null;
    final n = buildOfTag(tag, tagPrefix)!;
    if (n <= currentBuild) return null;
    final url = 'https://github.com/$repo/releases/download/$tag/${_assetName(rawBuild)}';
    return UpdateInfo(n, tag, url, 0, '');
  }

  /// Скачивает файл обновления и запускает установку.
  /// Android: открывает системный установщик. Windows: тихо запускает установщик
  /// (приложение после этого должно завершиться).
  /// Возвращает 'ok', 'permission' (Android: разрешить установку) или текст ошибки.
  static Future<String> downloadAndInstall(
      UpdateInfo u, void Function(double) onProgress) async {
    final String dir = Platform.isWindows
        ? Directory.systemTemp.path
        : (await _ch.invokeMethod<String>('cacheDir')) ?? Directory.systemTemp.path;
    final file = File(Platform.isWindows
        ? '$dir\\RelayFastVPN-Setup.exe'
        : '$dir/update.apk');
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
    final client = http.Client();
    try {
      final resp = await client
          .send(http.Request('GET', Uri.parse(u.apkUrl)))
          .timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200) return 'error: загрузка ${resp.statusCode}';
      final total = resp.contentLength ?? u.size;
      var got = 0;
      final sink = file.openWrite();
      await for (final chunk in resp.stream) {
        sink.add(chunk);
        got += chunk.length;
        if (total > 0) onProgress(got / total);
      }
      await sink.close();
      if (u.size > 0 && await file.length() != u.size) {
        return 'error: файл скачан не полностью';
      }
    } catch (e) {
      return 'error: $e';
    } finally {
      client.close();
    }
    if (Platform.isWindows) {
      try {
        // Установщик стартует через 3 секунды, когда приложение уже закрылось
        // и не держит свои файлы.
        final exe = file.path.replaceAll("'", "''");
        await Process.start(
          'powershell',
          [
            '-NoProfile',
            '-WindowStyle',
            'Hidden',
            '-Command',
            "Start-Sleep -Seconds 3; Start-Process -FilePath '$exe' -ArgumentList "
                "'/SILENT','/CLOSEAPPLICATIONS','/RESTARTAPPLICATIONS','/SUPPRESSMSGBOXES'"
          ],
          mode: ProcessStartMode.detached,
        );
        return 'ok';
      } catch (e) {
        return 'error: $e';
      }
    }
    final r = await _ch.invokeMethod<String>('installApk', {'path': file.path});
    return r ?? 'error';
  }
}
