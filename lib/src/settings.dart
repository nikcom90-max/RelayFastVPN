import 'package:shared_preferences/shared_preferences.dart';

const defaultPingUrl = 'https://www.gstatic.com/generate_204';

/// Пользовательские настройки приложения (хранятся на устройстве).
class AppSettings {
  /// dark | light | system
  String theme = 'dark';
  String pingUrl = defaultPingUrl;
  bool autoConnect = false;
  bool autoServer = false;

  /// Сам поднимать VPN при возврате в приложение, если он был включён,
  /// но система его отключила (экран долго был выключен).
  bool autoReconnect = true;

  /// Только Windows: 'proxy' — системный прокси, 'tun' — весь трафик через TUN.
  String desktopMode = 'proxy';

  /// off | bypass (выбранные приложения мимо VPN) | only (через VPN только выбранные)
  String splitMode = 'off';
  Set<String> splitApps = {};

  void load(SharedPreferences p) {
    theme = p.getString('s_theme') ?? 'dark';
    pingUrl = p.getString('s_ping_url') ?? defaultPingUrl;
    autoConnect = p.getBool('s_auto_connect') ?? false;
    autoServer = p.getBool('s_auto_server') ?? false;
    autoReconnect = p.getBool('s_auto_reconnect') ?? true;
    desktopMode = p.getString('s_desktop_mode') ?? 'proxy';
    splitMode = p.getString('s_split_mode') ?? 'off';
    splitApps = (p.getStringList('s_split_apps') ?? const []).toSet();
  }

  Future<void> save(SharedPreferences p) async {
    await p.setString('s_theme', theme);
    await p.setString('s_ping_url', pingUrl);
    await p.setBool('s_auto_connect', autoConnect);
    await p.setBool('s_auto_server', autoServer);
    await p.setBool('s_auto_reconnect', autoReconnect);
    await p.setString('s_desktop_mode', desktopMode);
    await p.setString('s_split_mode', splitMode);
    await p.setStringList('s_split_apps', splitApps.toList());
  }
}
