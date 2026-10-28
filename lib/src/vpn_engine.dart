import 'dart:async';

import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import 'windows/windows_engine.dart';

enum EngineState { stopped, starting, started, stopping, error }

class EngineStats {
  const EngineStats({
    this.up = 0,
    this.down = 0,
    this.sessUp = 0,
    this.sessDown = 0,
    this.totUp = 0,
    this.totDown = 0,
  });
  final int up, down, sessUp, sessDown, totUp, totDown;
}

class EngineStatus {
  const EngineStatus(this.state, [this.message]);
  final EngineState state;
  final String? message;

  static EngineStatus parse(String raw) {
    if (raw.startsWith('error:')) {
      return EngineStatus(EngineState.error, raw.substring(6));
    }
    switch (raw) {
      case 'starting':
        return const EngineStatus(EngineState.starting);
      case 'started':
        return const EngineStatus(EngineState.started);
      case 'stopping':
        return const EngineStatus(EngineState.stopping);
      default:
        return const EngineStatus(EngineState.stopped);
    }
  }
}

/// Движок VPN. На Android — мост к Kotlin (VpnService + Xray-core),
/// на Windows — запуск xray.exe (системный прокси или TUN через Wintun).
abstract class VpnEngine {
  factory VpnEngine() => Platform.isWindows ? WindowsVpnEngine() : AndroidVpnEngine();

  /// Для наследников из других файлов.
  VpnEngine.internal();

  /// Только Windows: 'proxy' — системный прокси, 'tun' — весь трафик через TUN.
  String desktopMode = 'proxy';

  Stream<EngineStatus> get status;

  Future<EngineStatus> current();

  /// Запрашивает у системы разрешение на VPN. true — можно стартовать.
  Future<bool> prepare();

  Future<void> start(
    String configJson, {
    String splitMode = 'off',
    List<String> splitApps = const [],
  });

  /// Горячая смена сервера.
  Future<void> reload(String configJson);

  Future<void> stop();

  /// Имя сервера для уведомления (только Android).
  Future<void> setServerName(String name) async {}

  /// Скорость (байт/с), трафик за сеанс и всего.
  Future<EngineStats> stats();

  Future<void> resetTraffic();

  /// Задержка до сервера в мс (-1 — не отвечает). Работает и без VPN.
  Future<int> ping(String configJson, {String? url});

  /// GET через уже поднятый туннель. -1 — нет ответа или VPN выключен.
  Future<int> check({String? url});

  // --- только Android (на Windows безвредные заглушки) --------------------

  Future<List<({String name, String package})>> installedApps() async => const [];

  Future<bool> batteryIgnored() async => true;

  Future<bool> requestIgnoreBattery() async => false;

  Future<bool> openVpnSettings() async => false;

  // --- только Windows ------------------------------------------------------

  /// Запущено ли приложение с правами администратора (нужно для режима TUN).
  Future<bool> isElevated() async => true;

  /// Перезапускает приложение от имени администратора.
  Future<void> relaunchElevated() async {}
}

/// Мост к нативной части на Android (Kotlin VpnService + Xray-core).
class AndroidVpnEngine extends VpnEngine {
  AndroidVpnEngine() : super.internal();

  static const _method = MethodChannel('relayfast/vpn');
  static const _events = EventChannel('relayfast/vpn_state');

  @override
  Stream<EngineStatus> get status =>
      _events.receiveBroadcastStream().map((e) => EngineStatus.parse('$e'));

  @override
  Future<EngineStatus> current() async =>
      EngineStatus.parse(await _method.invokeMethod<String>('state') ?? 'stopped');

  @override
  Future<bool> prepare() async =>
      await _method.invokeMethod<bool>('prepare') ?? false;

  @override
  Future<void> start(
    String configJson, {
    String splitMode = 'off',
    List<String> splitApps = const [],
  }) =>
      _method.invokeMethod('start', {
        'config': configJson,
        'splitMode': splitMode,
        'splitApps': splitApps,
      });

  @override
  Future<void> reload(String configJson) =>
      _method.invokeMethod('reload', {'config': configJson});

  @override
  Future<void> stop() => _method.invokeMethod('stop');

  @override
  Future<void> setServerName(String name) =>
      _method.invokeMethod('setServerName', {'name': name});

  @override
  Future<EngineStats> stats() async {
    final m = await _method.invokeMapMethod<String, dynamic>('stats');
    int g(String k) => (m?[k] as num?)?.toInt() ?? 0;
    return EngineStats(
      up: g('up'),
      down: g('down'),
      sessUp: g('sessUp'),
      sessDown: g('sessDown'),
      totUp: g('totUp'),
      totDown: g('totDown'),
    );
  }

  @override
  Future<void> resetTraffic() => _method.invokeMethod('resetTraffic');

  @override
  Future<int> ping(String configJson, {String? url}) async =>
      (await _method.invokeMethod<num>('ping', {'config': configJson, 'url': url}))
          ?.toInt() ??
      -1;

  @override
  Future<int> check({String? url}) async =>
      (await _method.invokeMethod<num>('check', {'url': url}))?.toInt() ?? -1;

  @override
  Future<List<({String name, String package})>> installedApps() async {
    final raw = await _method.invokeListMethod<Map>('apps') ?? const [];
    return [
      for (final m in raw)
        (name: '${m['name']}', package: '${m['package']}'),
    ];
  }

  @override
  Future<bool> batteryIgnored() async =>
      await _method.invokeMethod<bool>('batteryIgnored') ?? false;

  @override
  Future<bool> requestIgnoreBattery() async =>
      await _method.invokeMethod<bool>('requestBattery') ?? false;

  @override
  Future<bool> openVpnSettings() async =>
      await _method.invokeMethod<bool>('vpnSettings') ?? false;
}
