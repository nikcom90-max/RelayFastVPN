import 'dart:convert';

/// Превращает конфиг Android (inbound `tun` с fd) в конфиг для Windows.
///
/// [mode]: 'proxy' — только локальные http/socks (их включают как системный
/// прокси), 'tun' — дополнительно inbound `tun` (адаптер Wintun).
/// Всегда добавляется локальный API статистики (dokodemo-door + StatsService).
String desktopConfig(
  String json, {
  required String mode,
  int httpPort = 10809,
  int socksPort = 10808,
  int apiPort = 10085,
  String adapter = 'RelayFast',
}) {
  final cfg = jsonDecode(json) as Map<String, dynamic>;
  final sniffing = {
    'enabled': true,
    'destOverride': ['http', 'tls', 'quic'],
    // Без routeOnly: домен из TLS/HTTP уходит на сервер и резолвится там
    // (обход подмены DNS провайдером, как на Android).
    'routeOnly': false,
  };
  final inbounds = <dynamic>[
    {
      'tag': 'http-in',
      'listen': '127.0.0.1',
      'port': httpPort,
      'protocol': 'http',
      'settings': <String, dynamic>{},
      'sniffing': sniffing,
    },
    {
      'tag': 'socks-in',
      'listen': '127.0.0.1',
      'port': socksPort,
      'protocol': 'socks',
      'settings': {'auth': 'noauth', 'udp': true},
      'sniffing': sniffing,
    },
    {
      'tag': 'api',
      'listen': '127.0.0.1',
      'port': apiPort,
      'protocol': 'dokodemo-door',
      'settings': {'address': '127.0.0.1'},
    },
  ];
  if (mode == 'tun') {
    inbounds.add({
      'tag': 'tun',
      'protocol': 'tun',
      'settings': {'name': adapter, 'MTU': 1500, 'userLevel': 8},
      'sniffing': sniffing,
    });
  }
  cfg['inbounds'] = inbounds;
  cfg['api'] = {
    'tag': 'api',
    'services': ['StatsService'],
  };
  final routing = Map<String, dynamic>.from((cfg['routing'] as Map?) ?? const {});
  final rules = List<dynamic>.from((routing['rules'] as List?) ?? const []);
  rules.insert(0, {
    'type': 'field',
    'inboundTag': ['api'],
    'outboundTag': 'api',
  });
  routing['rules'] = rules;
  cfg['routing'] = routing;
  return jsonEncode(cfg);
}

/// Конфиг для одноразовой проверки задержки: один локальный http-inbound.
String pingConfig(String json, int httpPort) {
  final cfg = jsonDecode(json) as Map<String, dynamic>;
  cfg['inbounds'] = [
    {
      'tag': 'http-in',
      'listen': '127.0.0.1',
      'port': httpPort,
      'protocol': 'http',
      'settings': <String, dynamic>{},
    },
  ];
  cfg.remove('api');
  return jsonEncode(cfg);
}

/// Адреса (домены и IP) всех прокси-серверов из outbound'ов: для TUN их нужно
/// пускать мимо туннеля, иначе соединение с сервером зациклится.
List<String> serverHosts(String json) {
  final cfg = jsonDecode(json) as Map<String, dynamic>;
  final found = <String>{};

  void walk(dynamic node) {
    if (node is Map) {
      node.forEach((k, v) {
        if (k == 'address' && v is String && v.isNotEmpty) {
          found.add(v);
        } else {
          walk(v);
        }
      });
    } else if (node is List) {
      for (final v in node) {
        walk(v);
      }
    }
  }

  for (final o in (cfg['outbounds'] as List? ?? const [])) {
    if (o is! Map) continue;
    final proto = o['protocol'];
    if (proto == 'freedom' || proto == 'blackhole' || proto == 'dns') continue;
    walk(o['settings']);
  }
  return found.toList();
}
