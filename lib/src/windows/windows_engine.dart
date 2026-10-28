import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../vpn_engine.dart';
import 'desktop_config.dart';

class _EngineError implements Exception {
  _EngineError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// VPN на Windows: запускает ядро Xray (`core\rf-core.exe`) и включает либо
/// системный прокси (без прав администратора), либо TUN через Wintun
/// (нужны права администратора).
class WindowsVpnEngine extends VpnEngine {
  WindowsVpnEngine() : super.internal();

  static const _httpPort = 10809;
  static const _socksPort = 10808;
  static const _apiPort = 10085;
  static const _adapter = 'RelayFast';
  static const _defaultUrl = 'https://www.gstatic.com/generate_204';
  static const _inetKey =
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';

  final _events = StreamController<EngineStatus>.broadcast();
  EngineStatus _state = const EngineStatus(EngineState.stopped);
  Process? _core;
  bool _stopping = false;
  bool _recovered = false;
  bool? _elevated;
  String _runMode = 'proxy';
  List<String> _serverIps = [];
  final List<String> _log = [];

  // --- трафик ---------------------------------------------------------------
  int _speedUp = 0, _speedDown = 0;
  int _sessUp = 0, _sessDown = 0;
  int _totUp = 0, _totDown = 0;
  DateTime? _lastPoll;
  DateTime? _lastSave;
  bool _polling = false;
  bool _totalsLoaded = false;

  // --- пути -----------------------------------------------------------------

  String get _coreDir =>
      '${File(Platform.resolvedExecutable).parent.path}\\core';
  String get _corePath => '$_coreDir\\rf-core.exe';
  String get _dataDir =>
      '${Platform.environment['APPDATA'] ?? Directory.systemTemp.path}\\RelayFastVPN';

  Map<String, String> get _coreEnv => {'XRAY_LOCATION_ASSET': _coreDir};

  // --- состояние ------------------------------------------------------------

  @override
  Stream<EngineStatus> get status => _events.stream;

  void _set(EngineState s, [String? message]) {
    _state = EngineStatus(s, message);
    _events.add(_state);
  }

  @override
  Future<EngineStatus> current() async {
    await _recover();
    return _state;
  }

  @override
  Future<bool> prepare() async => true;

  /// После аварийного завершения мог остаться включённый системный прокси,
  /// маршруты и процесс ядра — приводим всё в порядок один раз за запуск.
  Future<void> _recover() async {
    if (_recovered) return;
    _recovered = true;
    try {
      await Process.run('taskkill', ['/F', '/IM', 'rf-core.exe']);
    } catch (_) {}
    await _restoreSystemProxy();
    await _removeTunRoutes();
  }

  // --- запуск и остановка ----------------------------------------------------

  @override
  Future<void> start(
    String configJson, {
    String splitMode = 'off',
    List<String> splitApps = const [],
  }) async {
    await _recover();
    if (_core != null) await _shutdown(silent: true);
    _stopping = false;
    _set(EngineState.starting);
    try {
      _runMode = desktopMode == 'tun' ? 'tun' : 'proxy';
      if (!File(_corePath).existsSync()) {
        throw _EngineError('Не найдено ядро (core\\rf-core.exe). Переустановите приложение.');
      }
      if (_runMode == 'tun') {
        if (!await isElevated()) {
          throw _EngineError(
              'Для режима TUN запустите приложение от имени администратора.');
        }
        if (!File('$_coreDir\\wintun.dll').existsSync()) {
          throw _EngineError('Не найден wintun.dll. Переустановите приложение.');
        }
      }
      await Directory('$_dataDir\\run').create(recursive: true);
      final cfgPath = '$_dataDir\\run\\config.json';
      await File(cfgPath).writeAsString(desktopConfig(
        configJson,
        mode: _runMode,
        httpPort: _httpPort,
        socksPort: _socksPort,
        apiPort: _apiPort,
        adapter: _adapter,
      ));

      _log.clear();
      final p = await Process.start(
        _corePath,
        ['run', '-c', cfgPath],
        workingDirectory: _coreDir,
        environment: _coreEnv,
      );
      _core = p;
      p.stdout.transform(utf8.decoder).listen(_onLog, onError: (_) {});
      p.stderr.transform(utf8.decoder).listen(_onLog, onError: (_) {});
      unawaited(p.exitCode.then((code) => _onExit(p, code)));

      if (!await _waitPort(_httpPort, () => identical(_core, p))) {
        throw _EngineError(_failMessage('Ядро не запустилось'));
      }
      if (_runMode == 'tun') {
        await _setupTun(configJson);
      } else {
        await _setSystemProxy();
      }
      _beginSession();
      _set(EngineState.started);
    } catch (e) {
      await _shutdown(silent: true);
      _set(EngineState.error, '$e');
    }
  }

  @override
  Future<void> reload(String configJson) => start(configJson);

  @override
  Future<void> stop() => _shutdown();

  Future<void> _shutdown({bool silent = false}) async {
    _stopping = true;
    final p = _core;
    if (!silent && _state.state != EngineState.stopped) _set(EngineState.stopping);
    await _cleanupNetwork();
    if (p != null) {
      p.kill();
      await p.exitCode.timeout(const Duration(seconds: 3), onTimeout: () {
        try {
          Process.runSync('taskkill', ['/F', '/PID', '${p.pid}']);
        } catch (_) {}
        return -1;
      });
    }
    _core = null;
    _endSession();
    _stopping = false;
    if (!silent) _set(EngineState.stopped);
  }

  void _onLog(String chunk) {
    for (final line in const LineSplitter().convert(chunk)) {
      if (line.trim().isEmpty) continue;
      _log.add(line.trim());
      if (_log.length > 20) _log.removeAt(0);
    }
  }

  String _failMessage(String prefix) {
    final tail = _log.isEmpty ? '' : ' ${_log.last}';
    return '$prefix.$tail';
  }

  void _onExit(Process p, int code) {
    if (_stopping || !identical(p, _core)) return;
    _core = null;
    final wasStarted = _state.state == EngineState.started;
    unawaited(_cleanupNetwork());
    _endSession();
    if (wasStarted) {
      _set(EngineState.error, _failMessage('Ядро остановилось (код $code)'));
    }
  }

  Future<void> _cleanupNetwork() async {
    try {
      await _restoreSystemProxy();
    } catch (_) {}
    try {
      await _removeTunRoutes();
    } catch (_) {}
  }

  Future<bool> _waitPort(int port, bool Function() alive) async {
    final end = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(end)) {
      if (!alive()) return false;
      try {
        final s = await Socket.connect('127.0.0.1', port,
            timeout: const Duration(milliseconds: 300));
        s.destroy();
        return true;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
    return false;
  }

  // --- системный прокси ------------------------------------------------------

  Future<ProcessResult> _ps(String script) => Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        script,
      ]);

  Future<String?> _regQuery(String name) async {
    try {
      final r = await Process.run('reg', ['query', _inetKey, '/v', name]);
      if (r.exitCode != 0) return null;
      final m = RegExp(r'REG_\w+\s+(.*)$', multiLine: true).firstMatch('${r.stdout}');
      return m?.group(1)?.trim();
    } catch (_) {
      return null;
    }
  }

  Future<void> _regSet(String name, String type, String value) =>
      Process.run('reg', ['add', _inetKey, '/v', name, '/t', type, '/d', value, '/f']);

  Future<void> _refreshInternetSettings() async {
    try {
      await _ps(r'''
$sig = '[DllImport("wininet.dll")] public static extern bool InternetSetOption(IntPtr h, int o, IntPtr b, int l);'
Add-Type -MemberDefinition $sig -Name WI -Namespace RF
[RF.WI]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0) | Out-Null
[RF.WI]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0) | Out-Null
''');
    } catch (_) {}
  }

  Future<void> _setSystemProxy() async {
    final prefs = await SharedPreferences.getInstance();
    if (!prefs.containsKey('win_prev_proxy')) {
      await prefs.setString(
        'win_prev_proxy',
        jsonEncode({
          'enable': await _regQuery('ProxyEnable'),
          'server': await _regQuery('ProxyServer'),
          'override': await _regQuery('ProxyOverride'),
        }),
      );
    }
    await _regSet('ProxyEnable', 'REG_DWORD', '1');
    await _regSet('ProxyServer', 'REG_SZ', '127.0.0.1:$_httpPort');
    await _regSet('ProxyOverride', 'REG_SZ',
        'localhost;127.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;172.2*;172.30.*;172.31.*;192.168.*;<local>');
    await _refreshInternetSettings();
  }

  Future<void> _restoreSystemProxy() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('win_prev_proxy');
    if (raw == null) return;
    Map<String, dynamic> prev = {};
    try {
      prev = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {}
    final enable = prev['enable'] as String?;
    final on = enable != null && (enable == '0x1' || enable == '1');
    await _regSet('ProxyEnable', 'REG_DWORD', on ? '1' : '0');
    final server = prev['server'] as String?;
    if (server != null && server.isNotEmpty) {
      await _regSet('ProxyServer', 'REG_SZ', server);
    } else {
      await Process.run('reg', ['delete', _inetKey, '/v', 'ProxyServer', '/f']);
    }
    final override = prev['override'] as String?;
    if (override != null && override.isNotEmpty) {
      await _regSet('ProxyOverride', 'REG_SZ', override);
    } else {
      await Process.run('reg', ['delete', _inetKey, '/v', 'ProxyOverride', '/f']);
    }
    await _refreshInternetSettings();
    await prefs.remove('win_prev_proxy');
  }

  // --- TUN -------------------------------------------------------------------

  Future<List<String>> _resolveServers(String configJson) async {
    final ips = <String>{};
    for (final host in serverHosts(configJson)) {
      final ip = InternetAddress.tryParse(host);
      if (ip != null) {
        if (ip.type == InternetAddressType.IPv4) ips.add(host);
        continue;
      }
      try {
        for (final a in await InternetAddress.lookup(host, type: InternetAddressType.IPv4)
            .timeout(const Duration(seconds: 5))) {
          ips.add(a.address);
        }
      } catch (_) {}
    }
    return ips.toList();
  }

  Future<void> _setupTun(String configJson) async {
    _serverIps = await _resolveServers(configJson);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('win_server_routes', _serverIps);
    final ips = _serverIps.map((e) => "'$e'").join(',');
    final script = r'''
$ErrorActionPreference = 'Stop'
$alias = '{ALIAS}'
for ($i = 0; $i -lt 40; $i++) {
  if (Get-NetAdapter -Name $alias -ErrorAction SilentlyContinue) { break }
  Start-Sleep -Milliseconds 250
}
if (-not (Get-NetAdapter -Name $alias -ErrorAction SilentlyContinue)) { throw 'Адаптер TUN не появился' }
$def = Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Where-Object { $_.InterfaceAlias -ne $alias } | Sort-Object RouteMetric | Select-Object -First 1
if ($def) {
  foreach ($ip in @({IPS})) {
    New-NetRoute -DestinationPrefix "$ip/32" -InterfaceIndex $def.InterfaceIndex -NextHop $def.NextHop -RouteMetric 1 -ErrorAction SilentlyContinue | Out-Null
  }
}
New-NetIPAddress -InterfaceAlias $alias -IPAddress 10.10.14.1 -PrefixLength 24 -ErrorAction SilentlyContinue | Out-Null
Set-NetIPInterface -InterfaceAlias $alias -InterfaceMetric 1 -ErrorAction SilentlyContinue
Set-DnsClientServerAddress -InterfaceAlias $alias -ServerAddresses '1.1.1.1','8.8.8.8'
New-NetRoute -DestinationPrefix '0.0.0.0/1' -InterfaceAlias $alias -NextHop '0.0.0.0' -RouteMetric 1 -ErrorAction SilentlyContinue | Out-Null
New-NetRoute -DestinationPrefix '128.0.0.0/1' -InterfaceAlias $alias -NextHop '0.0.0.0' -RouteMetric 1 -ErrorAction SilentlyContinue | Out-Null
'''
        .replaceAll('{ALIAS}', _adapter)
        .replaceAll('{IPS}', ips.isEmpty ? '' : ips);
    final r = await _ps(script);
    if (r.exitCode != 0) {
      final err = '${r.stderr}'.trim();
      throw _EngineError(
          'Не удалось настроить TUN${err.isEmpty ? '' : ': ${err.split('\n').first}'}');
    }
  }

  Future<void> _removeTunRoutes() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList('win_server_routes');
    final ips = <String>{..._serverIps, ...?saved};
    if (ips.isEmpty) return;
    final list = ips.map((e) => "'$e'").join(',');
    await _ps('foreach (\$ip in @($list)) { Remove-NetRoute -DestinationPrefix "\$ip/32" -Confirm:\$false -ErrorAction SilentlyContinue }');
    _serverIps = [];
    await prefs.remove('win_server_routes');
  }

  // --- права администратора --------------------------------------------------

  @override
  Future<bool> isElevated() async {
    final cached = _elevated;
    if (cached != null) return cached;
    try {
      final r = await _ps(
          '([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)');
      _elevated = '${r.stdout}'.trim().toLowerCase() == 'true';
    } catch (_) {
      _elevated = false;
    }
    return _elevated!;
  }

  @override
  Future<void> relaunchElevated() async {
    await _shutdown(silent: true);
    final exe = Platform.resolvedExecutable.replaceAll("'", "''");
    await Process.start(
      'powershell',
      [
        '-NoProfile',
        '-Command',
        "Start-Process -FilePath '$exe' -ArgumentList '--relaunch' -Verb RunAs"
      ],
      mode: ProcessStartMode.detached,
    );
    await Future<void>.delayed(const Duration(milliseconds: 500));
    exit(0);
  }

  // --- статистика ------------------------------------------------------------

  Future<void> _loadTotals() async {
    if (_totalsLoaded) return;
    _totalsLoaded = true;
    final p = await SharedPreferences.getInstance();
    _totUp = p.getInt('win_tot_up') ?? 0;
    _totDown = p.getInt('win_tot_down') ?? 0;
  }

  Future<void> _saveTotals() async {
    _lastSave = DateTime.now();
    final p = await SharedPreferences.getInstance();
    await p.setInt('win_tot_up', _totUp);
    await p.setInt('win_tot_down', _totDown);
  }

  void _beginSession() {
    _sessUp = 0;
    _sessDown = 0;
    _speedUp = 0;
    _speedDown = 0;
    _lastPoll = null;
  }

  void _endSession() {
    _speedUp = 0;
    _speedDown = 0;
    _lastPoll = null;
    if (_totalsLoaded) unawaited(_saveTotals());
  }

  @override
  Future<EngineStats> stats() async {
    await _loadTotals();
    if (_state.state == EngineState.started) await _pollCore();
    return EngineStats(
      up: _speedUp,
      down: _speedDown,
      sessUp: _sessUp,
      sessDown: _sessDown,
      totUp: _totUp,
      totDown: _totDown,
    );
  }

  /// Читает счётчики ядра (они сбрасываются при чтении). Не чаще раза в ~2 с:
  /// каждый опрос — отдельный вызов rf-core.exe.
  Future<void> _pollCore() async {
    if (_polling) return;
    final now = DateTime.now();
    if (_lastPoll != null && now.difference(_lastPoll!).inMilliseconds < 1800) return;
    _polling = true;
    try {
      final r = await Process.run(
        _corePath,
        ['api', 'statsquery', '-s', '127.0.0.1:$_apiPort', '-reset'],
        workingDirectory: _coreDir,
      ).timeout(const Duration(seconds: 3));
      if (r.exitCode != 0) return;
      final j = jsonDecode('${r.stdout}') as Map<String, dynamic>;
      var up = 0, down = 0;
      for (final e in (j['stat'] as List? ?? const [])) {
        final name = '${e['name']}';
        if (!name.startsWith('outbound>>>') || name.contains('>>>block>>>')) continue;
        final v = int.tryParse('${e['value']}') ?? 0;
        if (name.endsWith('>>>uplink')) {
          up += v;
        } else if (name.endsWith('>>>downlink')) {
          down += v;
        }
      }
      final dt = _lastPoll == null
          ? 1.0
          : (now.difference(_lastPoll!).inMilliseconds / 1000.0).clamp(0.5, 3600.0);
      _lastPoll = now;
      _speedUp = (up / dt).round();
      _speedDown = (down / dt).round();
      _sessUp += up;
      _sessDown += down;
      _totUp += up;
      _totDown += down;
      if (_lastSave == null || now.difference(_lastSave!).inSeconds >= 15) {
        unawaited(_saveTotals());
      }
    } catch (_) {
      // ядро занято или ещё не готово — повторим при следующем опросе
    } finally {
      _polling = false;
    }
  }

  @override
  Future<void> resetTraffic() async {
    await _loadTotals();
    _totUp = 0;
    _totDown = 0;
    await _saveTotals();
  }

  // --- задержка ---------------------------------------------------------------

  Future<int> _freePort() async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = s.port;
    await s.close();
    return port;
  }

  Future<int> _timedGet(int proxyPort, String url) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 6)
      ..findProxy = (_) => 'PROXY 127.0.0.1:$proxyPort';
    try {
      final sw = Stopwatch()..start();
      final req = await client.getUrl(Uri.parse(url));
      final res = await req.close().timeout(const Duration(seconds: 8));
      final ms = sw.elapsedMilliseconds;
      await res.drain<void>();
      return res.statusCode < 500 ? ms : -1;
    } catch (_) {
      return -1;
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<int> ping(String configJson, {String? url}) async {
    if (!File(_corePath).existsSync()) return -1;
    Directory? dir;
    Process? p;
    try {
      final port = await _freePort();
      dir = await Directory.systemTemp.createTemp('rfping');
      final f = File('${dir.path}\\c.json');
      await f.writeAsString(pingConfig(configJson, port));
      p = await Process.start(_corePath, ['run', '-c', f.path],
          workingDirectory: _coreDir, environment: _coreEnv);
      p.stdout.drain<void>();
      p.stderr.drain<void>();
      var exited = false;
      unawaited(p.exitCode.then((_) => exited = true));
      if (!await _waitPort(port, () => !exited)) return -1;
      return await _timedGet(port, (url == null || url.isEmpty) ? _defaultUrl : url);
    } catch (_) {
      return -1;
    } finally {
      p?.kill();
      try {
        await dir?.delete(recursive: true);
      } catch (_) {}
    }
  }

  @override
  Future<int> check({String? url}) async {
    if (_state.state != EngineState.started) return -1;
    return _timedGet(_httpPort, (url == null || url.isEmpty) ? _defaultUrl : url);
  }
}
