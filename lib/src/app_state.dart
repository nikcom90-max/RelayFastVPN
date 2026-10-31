import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform, exit;
import 'dart:math';
import 'dart:ui' show AppExitResponse;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';
import 'settings.dart';
import 'subscription_service.dart';
import 'update_service.dart';
import 'vpn_engine.dart';
import 'xray_config.dart';

enum BlockReason { none, kill, updateRequired }

/// Трафик через приложение: за текущий сеанс и за всё время (на этом телефоне).
class TrafficStats {
  const TrafficStats({
    this.sessionUp = 0,
    this.sessionDown = 0,
    this.totalUp = 0,
    this.totalDown = 0,
  });
  final int sessionUp;
  final int sessionDown;
  final int totalUp;
  final int totalDown;
}

/// Единый контроллер состояния приложения.
class AppController extends ChangeNotifier with WidgetsBindingObserver {
  AppController({VpnEngine? engine, SubscriptionService? subscriptions})
      : _engine = engine ?? VpnEngine(),
        _subs = subscriptions ?? SubscriptionService();

  final VpnEngine _engine;
  final SubscriptionService _subs;
  late SharedPreferences _prefs;

  String? osVersion; // версия Android, например «14»
  String? deviceModel; // например «samsung SM-S918B»
  String appVersion = '1.0.0';
  int build = 1;
  int rawBuild = 1;

  // --- обновления приложения (GitHub Releases) ---
  UpdateInfo? update;
  bool checkingUpdate = false;
  double? updateProgress; // 0..1 пока качается
  String? updateMessage;


  final AppSettings settings = AppSettings();

  /// Все подписки на устройстве и активная.
  List<SavedSub> subs = [];
  String? activeId;
  RemoteConfig remote = RemoteConfig.empty;

  List<ServerProfile> servers = [];
  final Map<String, int> delays = {}; // имя сервера → мс (-1 = нет ответа)
  String? selected;

  EngineStatus status = const EngineStatus(EngineState.stopped);
  String? error;
  bool refreshing = false;
  bool starting = false;
  bool pinging = false;
  bool checking = false;
  String? lastRefreshError; // для экрана диагностики
  final Set<String> testing = {}; // серверы, которые проверяются прямо сейчас

  /// Скорость обновляется отдельно от остального состояния, чтобы раз в секунду
  /// перерисовывался только маленький текст, а не весь экран.
  /// Текущая вкладка нижнего меню: 0 — главная, 1 — оплата.
  final ValueNotifier<int> tab = ValueNotifier(0);
  final ValueNotifier<TrafficStats> traffic = ValueNotifier(const TrafficStats());

  final ValueNotifier<({int up, int down})> speed = ValueNotifier((up: 0, down: 0));
  bool _inForeground = true;
  bool _wantConnected = false; // пользователь включил VPN и не выключал

  StreamSubscription<EngineStatus>? _statusSub;
  Timer? _refreshTimer;
  Timer? _statsTimer;
  DateTime? _lastRefresh;
  Completer<bool>? _startWaiter;

  // --- производные ---------------------------------------------------------

  SavedSub? get active {
    for (final s in subs) {
      if (s.id == activeId) return s;
    }
    return subs.isEmpty ? null : subs.first;
  }

  String? get subUrl => active?.url;
  SubscriptionInfo? get info => active?.info;
  bool get hasSubscription => active?.raw != null;
  bool get connected => status.state == EngineState.started;
  bool get busy =>
      starting ||
      status.state == EngineState.starting ||
      status.state == EngineState.stopping;

  String get brandName => remote.brandName ?? 'RelayFastVPN';

  BlockReason get blockReason {
    if (remote.killEnabled) return BlockReason.kill;
    if (remote.updateRequired(build)) return BlockReason.updateRequired;
    return BlockReason.none;
  }

  ServerProfile? get selectedProfile {
    for (final s in servers) {
      if (s.name == selected) return s;
    }
    return servers.isEmpty ? null : servers.first;
  }

  // --- обновления ----------------------------------------------------------

  /// [manual] — по нажатию кнопки: без ограничения по времени и с сообщением.
  Future<void> checkUpdate({bool manual = false}) async {
    if (!UpdateService.enabled || checkingUpdate) return;
    final last = _prefs.getInt('upd_last') ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!manual && now - last < 6 * 3600 * 1000) return;
    checkingUpdate = true;
    updateMessage = null;
    notifyListeners();
    try {
      update = await UpdateService.check(build, rawBuild);
      await _prefs.setInt('upd_last', now);
      if (manual && update == null) updateMessage = 'У вас последняя версия';
    } catch (e) {
      if (manual) updateMessage = 'Не удалось проверить: $e';
    }
    checkingUpdate = false;
    notifyListeners();
  }

  Future<void> installUpdate() async {
    final u = update;
    if (u == null || updateProgress != null) return;
    updateProgress = 0;
    updateMessage = null;
    notifyListeners();
    final r = await UpdateService.downloadAndInstall(u, (p) {
      updateProgress = p;
      notifyListeners();
    }, beforeInstall: () async {
      // Windows: перед запуском установщика отключаем VPN (он завершит приложение).
      try {
        await _engine.stop().timeout(const Duration(seconds: 6));
      } catch (_) {}
    });
    updateProgress = null;
    if (r == 'ok' && Platform.isWindows) {
      // Установщик запущен и сам закроет приложение; выходим, не дожидаясь.
      exit(0);
    }
    if (r == 'permission') {
      updateMessage = 'Разрешите установку из этого приложения и нажмите «Установить» ещё раз';
    } else if (r != 'ok') {
      updateMessage = 'Не удалось установить: ${r.replaceFirst('error: ', '')}';
    }
    notifyListeners();
  }

  // --- жизненный цикл ------------------------------------------------------

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    try {
      final pkg = await PackageInfo.fromPlatform();
      appVersion = pkg.version;
      // При сборке --split-per-abi Flutter прибавляет к номеру сборки 1000/2000/4000
      // (armeabi-v7a/arm64-v8a/x86_64): 2006 значит сборка №6 для arm64.
      final raw = int.tryParse(pkg.buildNumber) ?? 1;
      rawBuild = raw;
      build = raw >= 1000 ? raw % 1000 : raw;
    } catch (_) {}

    try {
      if (Platform.isWindows) {
        final w = await DeviceInfoPlugin().windowsInfo;
        osVersion = '${w.majorVersion}.${w.minorVersion}.${w.buildNumber}';
        deviceModel = 'Windows PC';
      } else {
        final a = await DeviceInfoPlugin().androidInfo;
        osVersion = a.version.release;
        final maker = a.manufacturer;
        final model = a.model;
        deviceModel = model.toLowerCase().startsWith(maker.toLowerCase())
            ? model
            : '$maker $model';
      }
    } catch (_) {}

    settings.load(_prefs);
    _wantConnected = _prefs.getBool('want_vpn') ?? false;
    unawaited(_pollStats());
    _loadSubs();
    selected = _prefs.getString('selected');
    final remoteRaw = _prefs.getString('remote');
    if (remoteRaw != null) {
      try {
        remote = RemoteConfig.fromJson(jsonDecode(remoteRaw));
      } catch (_) {}
    }
    _reloadServers();

    WidgetsBinding.instance.addObserver(this);
    _statusSub = _engine.status.listen(_onStatus);
    try {
      _onStatus(await _engine.current());
    } catch (_) {}

    notifyListeners();
    unawaited(checkUpdate());
    if (hasSubscription) {
      unawaited(refresh(silent: true));
      _scheduleRefresh();
      if (settings.autoConnect && !connected && blockReason == BlockReason.none) {
        unawaited(connect());
      }
    }
  }

  void _loadSubs() {
    final raw = _prefs.getString('subs');
    if (raw != null) {
      try {
        subs = [
          for (final j in jsonDecode(raw) as List)
            SavedSub.fromJson((j as Map).cast<String, dynamic>())
        ];
      } catch (_) {
        subs = [];
      }
      activeId = _prefs.getString('active_sub');
      return;
    }
    // Миграция со старой версии (одна подписка).
    final url = _prefs.getString('sub_url');
    final body = _prefs.getString('sub_raw');
    if (url != null && body != null) {
      SubscriptionInfo? info;
      final infoRaw = _prefs.getString('sub_info');
      if (infoRaw != null) {
        try {
          info = SubscriptionInfo.fromJson(jsonDecode(infoRaw));
        } catch (_) {}
      }
      final s = SavedSub(id: _newId(), url: url, raw: body, info: info);
      subs = [s];
      activeId = s.id;
      unawaited(_saveSubs());
    }
  }

  Future<void> _saveSubs() async {
    await _prefs.setString('subs', jsonEncode([for (final s in subs) s.toJson()]));
    if (activeId != null) {
      await _prefs.setString('active_sub', activeId!);
    } else {
      await _prefs.remove('active_sub');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _inForeground = state == AppLifecycleState.resumed;
    if (!_inForeground) {
      _statsTimer?.cancel();
      _statsTimer = null;
    } else if (connected) {
      _startStats();
    }
    if (state == AppLifecycleState.resumed) unawaited(_restoreAfterResume());
    if (state != AppLifecycleState.resumed || !hasSubscription) return;
    final last = _lastRefresh;
    if (last == null || DateTime.now().difference(last).inMinutes >= 5) {
      unawaited(refresh(silent: true));
    }
  }

  /// После долгого сна экрана система могла убить VPN: сверяем состояние и,
  /// если пользователь его не выключал, поднимаем заново.
  Future<void> _restoreAfterResume() async {
    try {
      _onStatus(await _engine.current());
    } catch (_) {}
    if (settings.autoReconnect &&
        _wantConnected &&
        hasSubscription &&
        !connected &&
        !busy &&
        blockReason == BlockReason.none) {
      await connect();
    }
  }

  void _setWanted(bool v) {
    _wantConnected = v;
    unawaited(_prefs.setBool('want_vpn', v));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _statusSub?.cancel();
    _refreshTimer?.cancel();
    _statsTimer?.cancel();
    super.dispose();
  }

  // --- настройки -----------------------------------------------------------

  Future<void> updateSettings(void Function(AppSettings s) change) async {
    change(settings);
    await settings.save(_prefs);
    notifyListeners();
  }

  // --- подписки ------------------------------------------------------------

  /// Короткое описание того, что сейчас загружено (для диагностики в настройках).
  String get subscriptionDiagnostics {
    final sub = active;
    if (sub == null) return 'Подписки нет';
    final raw = sub.raw?.trimLeft() ?? '';
    final format = raw.startsWith('[') || raw.startsWith('{')
        ? 'JSON Xray'
        : raw.isEmpty
            ? 'пусто'
            : 'список ссылок';
    final ua = sub.variant == 'compat' ? 'совместимый UA' : 'свой UA';
    final bal = servers.where((s) => s.isBalancer).length;
    final when = _lastRefresh == null
        ? 'ещё не обновлялась в этом запуске'
        : 'обновлена ${_lastRefresh!.hour.toString().padLeft(2, '0')}:'
            '${_lastRefresh!.minute.toString().padLeft(2, '0')}';
    return 'Формат: $format ($ua)\n'
        'Серверов: ${servers.length}, балансировщиков: $bal\n'
        'Подписка $when'
        '${lastRefreshError == null ? '' : '\nПоследняя ошибка: $lastRefreshError'}';
  }

  String get _hwid {
    var id = _prefs.getString('hwid');
    if (id == null) {
      id = _randomHex(16);
      _prefs.setString('hwid', id);
    }
    return id;
  }

  static String _randomHex(int bytes) {
    final r = Random.secure();
    return List.generate(bytes, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'))
        .join();
  }

  static String _newId() => DateTime.now().microsecondsSinceEpoch.toString();

  /// Добавляет подписку (или обновляет такую же ссылку) и делает её активной.
  Future<bool> importSubscription(String url) async {
    var text = url.trim();
    // Принимаем и deep link вида relayfast://import?url=...
    final deep = Uri.tryParse(text);
    if (deep != null && deep.scheme == 'relayfast') {
      text = deep.queryParameters['url'] ?? text;
    }
    final uri = Uri.tryParse(text);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      error = 'Некорректная ссылка.';
      notifyListeners();
      return false;
    }
    refreshing = true;
    error = null;
    notifyListeners();
    try {
      final res = await _subs.fetch(uri,
          appVersion: appVersion,
          hwid: _hwid,
          osVersion: osVersion,
          deviceModel: deviceModel,
          preferred: null);
      final link = uri.toString();
      SavedSub? sub;
      for (final s in subs) {
        if (s.url == link) sub = s;
      }
      if (sub == null) {
        sub = SavedSub(id: _newId(), url: link);
        subs.add(sub);
      }
      activeId = sub.id;
      _apply(sub, res);
      _scheduleRefresh();
      return true;
    } on SubscriptionException catch (e) {
      error = e.message;
    } catch (e) {
      error = 'Не удалось обработать подписку: $e';
    } finally {
      refreshing = false;
      notifyListeners();
    }
    return false;
  }

  Future<bool> refresh({bool silent = false}) async {
    final sub = active;
    if (sub == null || refreshing) return false;
    refreshing = true;
    if (!silent) error = null;
    notifyListeners();
    try {
      final res = await _subs.fetch(Uri.parse(sub.url),
          appVersion: appVersion,
          hwid: _hwid,
          osVersion: osVersion,
          deviceModel: deviceModel,
          preferred: sub.variant);
      _apply(sub, res);
      _lastRefresh = DateTime.now();
      lastRefreshError = null;
      return true;
    } on SubscriptionException catch (e) {
      lastRefreshError = e.message;
      if (!silent) error = e.message;
      return false;
    } catch (e) {
      lastRefreshError = '$e';
      if (!silent) error = 'Не удалось обработать подписку: $e';
      return false;
    } finally {
      refreshing = false;
      notifyListeners();
    }
  }

  void _apply(SavedSub sub, SubscriptionResult res) {
    sub.raw = res.body;
    sub.variant = res.variant;
    sub.info = res.info;
    if (res.remote != null) remote = res.remote!;
    if (res.remote != null) {
      _prefs.setString('remote', jsonEncode(res.remote!.toJson()));
    }
    unawaited(_saveSubs());
    _reloadServers();
    if (connected && blockReason != BlockReason.none) {
      unawaited(userDisconnect());
    }
  }

  void _reloadServers() {
    final raw = active?.raw;
    servers = raw == null ? [] : SubscriptionParser.parse(raw);
    if (servers.isNotEmpty && !servers.any((s) => s.name == selected)) {
      selected = servers.first.name;
    }
    delays.removeWhere((k, _) => !servers.any((s) => s.name == k));
  }

  void _scheduleRefresh() {
    _refreshTimer?.cancel();
    final h = (info?.updateIntervalHours ?? 12).clamp(1, 72);
    _refreshTimer =
        Timer.periodic(Duration(hours: h), (_) => refresh(silent: true));
  }

  /// Переключение на другую сохранённую подписку.
  Future<void> switchSub(String id) async {
    if (id == activeId) return;
    if (connected) await userDisconnect();
    activeId = id;
    delays.clear();
    _reloadServers();
    await _saveSubs();
    _scheduleRefresh();
    notifyListeners();
    unawaited(refresh(silent: true));
  }

  /// Удаляет активную подписку с устройства.
  Future<void> removeActiveSub() async {
    await userDisconnect();
    final cur = active;
    if (cur != null) subs.remove(cur);
    activeId = subs.isEmpty ? null : subs.first.id;
    delays.clear();
    selected = null;
    _reloadServers();
    await _saveSubs();
    _refreshTimer?.cancel();
    if (subs.isNotEmpty) _scheduleRefresh();
    notifyListeners();
  }

  // --- подключение ---------------------------------------------------------

  /// Порядок серверов для подключения: сначала самые быстрые.
  List<ServerProfile> _byDelay() {
    final list = [...servers];
    int key(ServerProfile s) {
      final d = delays[s.name];
      return (d == null || d < 0) ? 1 << 30 : d;
    }

    list.sort((a, b) => key(a).compareTo(key(b)));
    return list;
  }

  Future<void> connect() async {
    if (busy || connected) return;
    if (blockReason != BlockReason.none) return;
    if (selectedProfile == null) {
      error = 'Сначала добавьте подписку.';
      notifyListeners();
      return;
    }
    if (info?.expired == true) {
      error = 'Срок подписки истёк. Продлите её и обновите список.';
      notifyListeners();
      return;
    }
    if (info?.trafficExhausted == true) {
      error = 'Трафик по подписке исчерпан.';
      notifyListeners();
      return;
    }

    starting = true;
    error = null;
    notifyListeners();
    try {
      if (!await _engine.prepare()) {
        error = 'Нужно разрешить создание VPN-подключения.';
        return;
      }

      if (!settings.autoServer) {
        await _startWith(selectedProfile!);
        return;
      }

      // Авто: проверяем все серверы и пробуем самые быстрые по очереди.
      if (delays.isEmpty) await testDelays();
      final candidates = _byDelay().take(3).toList();
      for (var i = 0; i < candidates.length; i++) {
        final s = candidates[i];
        selected = s.name;
        notifyListeners();
        final waiter = _startWaiter = Completer<bool>();
        await _startWith(s);
        final ok = await waiter.future
            .timeout(const Duration(seconds: 25), onTimeout: () => false);
        _startWaiter = null;
        if (ok) {
          error = null;
          return;
        }
        await disconnect();
        await Future<void>.delayed(const Duration(milliseconds: 800));
      }
      error = 'Не удалось подключиться ни к одному серверу.';
    } on ConfigException catch (e) {
      error = e.message;
    } catch (e) {
      error = 'Не удалось запустить: $e';
    } finally {
      starting = false;
      notifyListeners();
    }
  }

  Future<void> _startWith(ServerProfile profile) async {
    _engine.desktopMode = settings.desktopMode;
    final config = XrayConfigBuilder.build(profile);
    unawaited(_engine.setServerName(profile.name).catchError((_) {}));
    await _engine.start(
      config,
      splitMode: settings.splitMode,
      splitApps: settings.splitApps.toList(),
    );
  }

  /// Внутреннее отключение (не меняет «хочу VPN включённым»).
  Future<void> disconnect() async {
    try {
      await _engine.stop();
    } catch (_) {}
  }

  /// Отключение по воле пользователя: автоподъём после этого не нужен.
  Future<void> userDisconnect() async {
    _setWanted(false);
    await disconnect();
  }

  Future<void> toggle() => connected ? userDisconnect() : connect();

  /// Проверка работающего туннеля: GET через ядро. Возвращает мс или -1.
  Future<int> checkConnection() async {
    if (!connected || checking) return -1;
    checking = true;
    notifyListeners();
    try {
      return await _engine.check(url: settings.pingUrl);
    } catch (_) {
      return -1;
    } finally {
      checking = false;
      notifyListeners();
    }
  }

  void _onStatus(EngineStatus s) {
    status = s;
    if (s.state == EngineState.started) {
      if (!_wantConnected) _setWanted(true);
      _startStats();
      _startWaiter?.complete(true);
    } else if (s.state == EngineState.stopped || s.state == EngineState.error) {
      if (s.state == EngineState.error) error = s.message ?? 'Ошибка ядра.';
      _stopStats();
      _startWaiter?.complete(false);
    }
    if (s.state == EngineState.started || s.state == EngineState.stopped ||
        s.state == EngineState.error) {
      _startWaiter = null;
    }
    notifyListeners();
  }

  void _startStats() {
    _statsTimer?.cancel();
    if (!_inForeground) return; // в фоне не опрашиваем — экономим батарею
    unawaited(_pollStats());
    _statsTimer = Timer.periodic(const Duration(seconds: 2), (_) => _pollStats());
  }

  /// Скорость и трафик считает нативная часть (её же читает уведомление).
  Future<void> _pollStats() async {
    try {
      final s = await _engine.stats();
      speed.value = (up: s.up, down: s.down);
      traffic.value = TrafficStats(
        sessionUp: s.sessUp,
        sessionDown: s.sessDown,
        totalUp: s.totUp,
        totalDown: s.totDown,
      );
    } catch (_) {}
  }

  /// Обнуляет счётчик «всего через приложение».
  Future<void> resetTotalTraffic() async {
    try {
      await _engine.resetTraffic();
    } catch (_) {}
    await _pollStats();
  }

  void _stopStats() {
    _statsTimer?.cancel();
    _statsTimer = null;
    speed.value = (up: 0, down: 0);
    unawaited(_pollStats());
  }

  // --- серверы -------------------------------------------------------------

  /// Ручной выбор сервера выключает режим «Авто».
  Future<void> selectServer(String name) async {
    selected = name;
    await _prefs.setString('selected', name);
    if (settings.autoServer) {
      await updateSettings((s) => s.autoServer = false);
    }
    notifyListeners();
    final p = selectedProfile;
    if (connected && p != null) {
      try {
        _engine.desktopMode = settings.desktopMode;
        unawaited(_engine.setServerName(p.name).catchError((_) {}));
        await _engine.reload(XrayConfigBuilder.build(p));
      } catch (e) {
        error = 'Не удалось переключить сервер: $e';
        notifyListeners();
      }
    }
  }

  /// Проверка одного сервера (по нажатию пользователя).
  Future<void> testOne(String name) async {
    if (testing.contains(name) || pinging) return;
    ServerProfile? p;
    for (final s in servers) {
      if (s.name == name) p = s;
    }
    if (p == null) return;
    testing.add(name);
    delays.remove(name);
    notifyListeners();
    int ms;
    try {
      ms = await _engine.ping(XrayConfigBuilder.build(p, tun: false),
          url: settings.pingUrl);
    } catch (_) {
      ms = -1;
    }
    delays[name] = ms;
    testing.remove(name);
    notifyListeners();
  }

  /// Замер задержек по всем серверам (по 3 одновременно).
  Future<void> testDelays() async {
    if (pinging) return;
    pinging = true;
    delays.clear();
    notifyListeners();
    try {
      final list = [...servers];
      for (var i = 0; i < list.length; i += 3) {
        final chunk = list.skip(i).take(3).toList();
        await Future.wait(chunk.map((s) async {
          int ms;
          try {
            ms = await _engine.ping(XrayConfigBuilder.build(s, tun: false),
                url: settings.pingUrl);
          } catch (_) {
            ms = -1;
          }
          delays[s.name] = ms;
          notifyListeners();
        }));
      }
    } finally {
      pinging = false;
      notifyListeners();
    }
  }

  bool get isWindows => Platform.isWindows;
  Future<bool> isElevated() => _engine.isElevated();
  Future<void> relaunchElevated() => _engine.relaunchElevated();

  /// Закрытие окна на Windows: сначала отключаем VPN (вернуть системный прокси,
  /// убрать маршруты), только потом выходим.
  @override
  Future<AppExitResponse> didRequestAppExit() async {
    if (Platform.isWindows) {
      try {
        await _engine.stop().timeout(const Duration(seconds: 6));
      } catch (_) {}
    }
    return AppExitResponse.exit;
  }

  Future<bool> batteryIgnored() => _engine.batteryIgnored();
  Future<bool> requestIgnoreBattery() => _engine.requestIgnoreBattery();
  Future<bool> openVpnSettings() => _engine.openVpnSettings();

  /// Установленные приложения (для раздельного туннелирования).
  Future<List<({String name, String package})>> installedApps() =>
      _engine.installedApps();
}
