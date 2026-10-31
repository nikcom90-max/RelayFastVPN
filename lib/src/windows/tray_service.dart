import 'dart:async';
import 'dart:io' show Platform, exit;

import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../app_state.dart';

/// Значок в трее Windows: статус подключения, меню и сворачивание в трей
/// при закрытии окна. На других платформах ничего не делает.
class TrayService with TrayListener, WindowListener {
  TrayService._(this._c);
  final AppController _c;

  bool _quitting = false;
  String _state = '';

  static TrayService? _instance;

  static Future<void> start(AppController c) async {
    if (!Platform.isWindows || _instance != null) return;
    try {
      final s = TrayService._(c);
      await s._init();
      _instance = s;
    } catch (e) {
      // без трея приложение работает как раньше (крестик закрывает окно)
      debugPrint('tray: $e');
    }
  }

  Future<void> _init() async {
    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true);
    windowManager.addListener(this);
    trayManager.addListener(this);
    _c.addListener(_refresh);
    await _refresh();
  }

  static final _flagEmoji = RegExp('[\u{1F1E6}-\u{1F1FF}]', unicode: true);

  String get _serverName {
    final n = (_c.selectedProfile?.name ?? '')
        .replaceAll(_flagEmoji, '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return n.length > 70 ? '${n.substring(0, 70)}…' : n;
  }

  Future<void> _refresh() async {
    final on = _c.connected;
    final name = _serverName;
    final key = '$on|$name';
    if (key == _state) return;
    _state = key;
    try {
      await trayManager.setIcon(
          on ? 'assets/tray/tray_on.ico' : 'assets/tray/tray_off.ico');
      await trayManager.setToolTip(on
          ? 'RelayFastVPN — подключено${name.isEmpty ? '' : '\n$name'}'
          : 'RelayFastVPN — отключено');
      await trayManager.setContextMenu(Menu(items: [
        MenuItem(key: 'show', label: 'Открыть RelayFastVPN'),
        MenuItem.separator(),
        MenuItem(key: 'toggle', label: on ? 'Отключить' : 'Подключить'),
        MenuItem.separator(),
        MenuItem(key: 'quit', label: 'Выход'),
      ]));
    } catch (e) {
      debugPrint('tray refresh: $e');
    }
  }

  Future<void> _show() async {
    if (await windowManager.isMinimized()) await windowManager.restore();
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _quit() async {
    _quitting = true;
    try {
      if (_c.connected) {
        await _c.userDisconnect().timeout(const Duration(seconds: 6));
      }
    } catch (_) {}
    try {
      await trayManager.destroy();
    } catch (_) {}
    exit(0);
  }

  // --- окно ---

  @override
  void onWindowClose() {
    if (_quitting) return;
    // крестик убирает окно в трей, VPN продолжает работать
    unawaited(windowManager.hide());
  }

  // --- значок в трее ---

  @override
  void onTrayIconMouseDown() => unawaited(_show());

  @override
  void onTrayIconRightMouseDown() => unawaited(trayManager.popUpContextMenu());

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        unawaited(_show());
      case 'toggle':
        unawaited(_c.toggle());
      case 'quit':
        unawaited(_quit());
    }
  }
}
