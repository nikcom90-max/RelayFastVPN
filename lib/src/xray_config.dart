import 'dart:convert';

class ConfigException implements Exception {
  ConfigException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Один сервер из подписки: либо полный конфиг Xray (xray-json из Remnawave),
/// либо отдельный outbound, собранный из ссылки (vless://, hysteria2://, ...).
class ServerProfile {
  ServerProfile(this.name, {this.fullConfig, this.outbound})
      : assert(fullConfig != null || outbound != null);

  final String name;
  final Map<String, dynamic>? fullConfig;
  final Map<String, dynamic>? outbound;

  /// Конфиг с балансировщиком (routing.balancers) — «Самые быстрые» и т. п.
  bool get isBalancer {
    final r = fullConfig?['routing'];
    final b = r is Map ? r['balancers'] : null;
    return b is List && b.isNotEmpty;
  }

  /// Метки для списка: протокол, транспорт, защита (например VLESS · TCP · REALITY).
  List<String> get tags {
    final t = _protoTags;
    return isBalancer ? ['БАЛАНСИРОВЩИК', ...t] : t;
  }

  List<String> get _protoTags {
    Map? ob = outbound;
    if (ob == null) {
      final list = fullConfig?['outbounds'];
      if (list is List) {
        for (final o in list) {
          if (o is Map && o['tag'] == 'proxy') ob = o;
        }
        if (ob == null) {
          for (final o in list) {
            if (o is Map &&
                o['protocol'] != 'freedom' &&
                o['protocol'] != 'blackhole' &&
                o['protocol'] != 'dns') {
              ob = o;
              break;
            }
          }
        }
      }
    }
    if (ob == null) return const [];
    final proto = '${ob['protocol'] ?? ''}';
    final ss = ob['streamSettings'];
    final net = ss is Map ? '${ss['network'] ?? 'tcp'}' : 'tcp';
    final sec = ss is Map ? '${ss['security'] ?? ''}' : '';
    final protoName = proto == 'shadowsocks' ? 'Shadowsocks' : proto.toUpperCase();
    return [
      protoName,
      if (net != 'hysteria') net.toUpperCase(),
      if (sec.isNotEmpty && sec != 'none') sec.toUpperCase(),
    ];
  }
}

/// Разбор тела подписки. Понимает те же форматы, что и INCY:
/// JSON (массив полных конфигов Xray или один конфиг), список ссылок
/// (в base64 или открытым текстом): vless, trojan, ss, hysteria2/hy2.
/// Нераспознанные записи пропускаются, а не ломают всю подписку.
class SubscriptionParser {
  static List<ServerProfile> parse(String body) {
    final text = body.trim().replaceFirst('\uFEFF', '');
    if (text.isEmpty) return [];

    final out = <ServerProfile>[];
    if (text.startsWith('[') || text.startsWith('{')) {
      dynamic json;
      try {
        json = jsonDecode(text);
      } catch (_) {
        return [];
      }
      final items = json is List ? json : [json];
      var i = 0;
      for (final item in items) {
        i++;
        if (item is! Map || item['outbounds'] is! List) continue;
        final cfg = Map<String, dynamic>.from(item);
        out.add(ServerProfile(_nameOfConfig(cfg, i), fullConfig: cfg));
      }
    } else {
      var lines = text;
      if (!text.contains('://')) {
        final decoded = _tryBase64(text);
        if (decoded == null) return [];
        lines = decoded;
      }
      for (final raw in lines.split(RegExp(r'\r?\n'))) {
        final line = raw.trim();
        if (line.isEmpty || line.startsWith('#')) continue;
        try {
          final p = LinkParser.parse(line);
          if (p != null) out.add(p);
        } catch (_) {
          // битая запись — пропускаем
        }
      }
    }
    return _uniqueNames(out);
  }

  static String _nameOfConfig(Map<String, dynamic> cfg, int index) {
    final r = cfg['remarks'] ?? cfg['ps'];
    if (r is String && r.trim().isNotEmpty) return r.trim();
    return 'Сервер $index';
  }

  static List<ServerProfile> _uniqueNames(List<ServerProfile> list) {
    final seen = <String, int>{};
    final out = <ServerProfile>[];
    for (final p in list) {
      final n = (seen[p.name] ?? 0) + 1;
      seen[p.name] = n;
      out.add(n == 1
          ? p
          : ServerProfile('${p.name} ($n)',
              fullConfig: p.fullConfig, outbound: p.outbound));
    }
    return out;
  }

  static String? _tryBase64(String s) {
    try {
      var t = s.replaceAll(RegExp(r'\s'), '').replaceAll('-', '+').replaceAll('_', '/');
      while (t.length % 4 != 0) {
        t += '=';
      }
      return utf8.decode(base64.decode(t), allowMalformed: true);
    } catch (_) {
      return null;
    }
  }
}

/// Ссылка → outbound Xray.
class LinkParser {
  static ServerProfile? parse(String link) {
    final scheme = link.split('://').first.toLowerCase();
    switch (scheme) {
      case 'vless':
        return _vless(link);
      case 'trojan':
        return _trojan(link);
      case 'ss':
        return _shadowsocks(link);
      case 'hysteria2':
      case 'hy2':
        return _hysteria2(link);
      default:
        return null; // vmess/tuic/wireguard и т.д. пока не поддерживаются
    }
  }

  static String _name(Uri u, String fallback) {
    final f = u.fragment;
    if (f.isEmpty) return fallback;
    try {
      return Uri.decodeComponent(f);
    } catch (_) {
      return f;
    }
  }

  static bool _truthy(String? v) => v == '1' || v == 'true';

  static ServerProfile _vless(String link) {
    final u = Uri.parse(link);
    final q = u.queryParameters;
    if (u.userInfo.isEmpty || u.host.isEmpty || u.port == 0) {
      throw const FormatException('bad vless link');
    }
    final ob = <String, dynamic>{
      'tag': 'proxy',
      'protocol': 'vless',
      'settings': {
        'address': u.host,
        'port': u.port,
        'id': Uri.decodeComponent(u.userInfo),
        'encryption': q['encryption'] ?? 'none',
        if ((q['flow'] ?? '').isNotEmpty) 'flow': q['flow'],
      },
      'streamSettings': _stream(u, q, 'none'),
    };
    return ServerProfile(_name(u, u.host), outbound: ob);
  }

  static ServerProfile _trojan(String link) {
    final u = Uri.parse(link);
    final q = u.queryParameters;
    if (u.userInfo.isEmpty || u.host.isEmpty || u.port == 0) {
      throw const FormatException('bad trojan link');
    }
    final ob = <String, dynamic>{
      'tag': 'proxy',
      'protocol': 'trojan',
      'settings': {
        'address': u.host,
        'port': u.port,
        'password': Uri.decodeComponent(u.userInfo),
      },
      'streamSettings': _stream(u, q, 'tls'),
    };
    return ServerProfile(_name(u, u.host), outbound: ob);
  }

  static ServerProfile _shadowsocks(String link) {
    // ss://BASE64(method:password)@host:port#name  или  ss://BASE64(method:password@host:port)#name
    final noScheme = link.substring(5);
    final hashIdx = noScheme.indexOf('#');
    final name = hashIdx >= 0
        ? Uri.decodeComponent(noScheme.substring(hashIdx + 1))
        : '';
    var main = hashIdx >= 0 ? noScheme.substring(0, hashIdx) : noScheme;
    final qIdx = main.indexOf('?');
    if (qIdx >= 0) main = main.substring(0, qIdx);

    String method, password, host;
    int port;
    if (main.contains('@')) {
      final at = main.lastIndexOf('@');
      var cred = main.substring(0, at);
      if (!cred.contains(':')) cred = SubscriptionParser._tryBase64(cred) ?? cred;
      final hp = main.substring(at + 1);
      final c = cred.indexOf(':');
      method = Uri.decodeComponent(cred.substring(0, c));
      password = Uri.decodeComponent(cred.substring(c + 1));
      final h = Uri.parse('x://$hp');
      host = h.host;
      port = h.port;
    } else {
      final decoded = SubscriptionParser._tryBase64(main) ?? '';
      final at = decoded.lastIndexOf('@');
      final cred = decoded.substring(0, at);
      final c = cred.indexOf(':');
      method = cred.substring(0, c);
      password = cred.substring(c + 1);
      final h = Uri.parse('x://${decoded.substring(at + 1)}');
      host = h.host;
      port = h.port;
    }
    final ob = <String, dynamic>{
      'tag': 'proxy',
      'protocol': 'shadowsocks',
      'settings': {
        'address': host,
        'port': port,
        'method': method,
        'password': password,
      },
    };
    return ServerProfile(name.isEmpty ? host : name, outbound: ob);
  }

  static ServerProfile _hysteria2(String link) {
    final u = Uri.parse(link.replaceFirst(RegExp(r'^hy2://', caseSensitive: false), 'hysteria2://'));
    final q = u.queryParameters;
    if (u.userInfo.isEmpty || u.host.isEmpty || u.port == 0) {
      throw const FormatException('bad hysteria2 link');
    }
    final tls = <String, dynamic>{
      'serverName': q['sni'] ?? u.host,
      'alpn': ['h3'],
      'allowInsecure': _truthy(q['insecure']) || _truthy(q['allowInsecure']),
      if ((q['pinSHA256'] ?? '').isNotEmpty)
        'pinnedPeerCertSha256': q['pinSHA256']!.replaceAll(':', '').toLowerCase(),
    };
    final ob = <String, dynamic>{
      'tag': 'proxy',
      'protocol': 'hysteria',
      'settings': {'version': 2, 'address': u.host, 'port': u.port},
      'streamSettings': {
        'network': 'hysteria',
        'security': 'tls',
        'tlsSettings': tls,
        'hysteriaSettings': {
          'version': 2,
          'auth': Uri.decodeComponent(u.userInfo),
        },
      },
    };
    return ServerProfile(_name(u, u.host), outbound: ob);
  }

  /// streamSettings из параметров ссылки (общие для vless/trojan).
  static Map<String, dynamic> _stream(
      Uri u, Map<String, String> q, String defaultSecurity) {
    var network = (q['type'] ?? 'tcp').toLowerCase();
    if (network == 'splithttp') network = 'xhttp';
    final security = (q['security'] ?? defaultSecurity).toLowerCase();

    final s = <String, dynamic>{'network': network, 'security': security};

    if (security == 'tls') {
      s['tlsSettings'] = {
        'serverName': q['sni'] ?? q['host'] ?? u.host,
        'fingerprint': q['fp'] ?? 'chrome',
        if ((q['alpn'] ?? '').isNotEmpty) 'alpn': q['alpn']!.split(','),
        'allowInsecure': _truthy(q['allowInsecure']) || _truthy(q['insecure']),
      };
    } else if (security == 'reality') {
      s['realitySettings'] = {
        'serverName': q['sni'] ?? u.host,
        'fingerprint': q['fp'] ?? 'chrome',
        'publicKey': q['pbk'] ?? '',
        'shortId': q['sid'] ?? '',
        'spiderX': q['spx'] ?? '',
      };
    }

    switch (network) {
      case 'ws':
        s['wsSettings'] = {
          'path': q['path'] ?? '/',
          if ((q['host'] ?? '').isNotEmpty) 'headers': {'Host': q['host']},
        };
      case 'grpc':
        s['grpcSettings'] = {
          'serviceName': q['serviceName'] ?? '',
          'multiMode': q['mode'] == 'multi',
        };
      case 'httpupgrade':
        s['httpupgradeSettings'] = {
          'path': q['path'] ?? '/',
          if ((q['host'] ?? '').isNotEmpty) 'host': q['host'],
        };
      case 'xhttp':
        Object? extra;
        if ((q['extra'] ?? '').isNotEmpty) {
          try {
            extra = jsonDecode(q['extra']!);
          } catch (_) {}
        }
        s['xhttpSettings'] = {
          'path': q['path'] ?? '/',
          if ((q['host'] ?? '').isNotEmpty) 'host': q['host'],
          if ((q['mode'] ?? '').isNotEmpty) 'mode': q['mode'],
          if (extra != null) 'extra': extra,
        };
    }
    return s;
  }
}

/// Собирает итоговый конфиг Xray для запуска.
class XrayConfigBuilder {
  /// [tun] — true для VPN-режима (inbound `tun`, fd подставляет нативная часть);
  /// false — для проверки задержки (без inbound).
  static String build(ServerProfile p, {bool tun = true}) {
    final Map<String, dynamic> cfg;
    if (p.fullConfig != null) {
      cfg = _deepCopy(p.fullConfig!);
    } else {
      cfg = _generated(p.outbound!);
    }

    cfg['log'] = {'loglevel': 'warning'};
    cfg['stats'] = <String, dynamic>{};
    final policy = Map<String, dynamic>.from((cfg['policy'] as Map?) ?? const {});
    final system = Map<String, dynamic>.from((policy['system'] as Map?) ?? const {});
    system['statsOutboundUplink'] = true;
    system['statsOutboundDownlink'] = true;
    policy['system'] = system;
    // inbound tun работает на уровне 8 — берём для него те же таймауты, что у уровня 0
    final levels = Map<String, dynamic>.from((policy['levels'] as Map?) ?? const {});
    if (levels['0'] is Map && levels['8'] == null) levels['8'] = levels['0'];
    if (levels.isNotEmpty) policy['levels'] = levels;
    cfg['policy'] = policy;

    cfg['inbounds'] = tun
        ? [
            {
              'tag': 'tun',
              'protocol': 'tun',
              'settings': {'name': 'xray0', 'MTU': 1500, 'userLevel': 8},
              // Без routeOnly: домен из TLS/HTTP подставляется в соединение и
              // резолвится на стороне сервера. Так обходится подмена DNS
              // провайдером (google.com отдавал левый IP → пустой ответ).
              // Приложения, ходящие по голым IP (Telegram), sniffing не затрагивает.
              'sniffing': {
                'enabled': true,
                'destOverride': ['http', 'tls'],
                'routeOnly': false,
              },
            }
          ]
        : <dynamic>[];

    if ((cfg['outbounds'] as List).isEmpty) {
      throw ConfigException('В конфиге сервера нет outbound.');
    }
    if (tun) {
      // внутренний DNS Xray отдаёт только IPv4: IPv6 из туннеля всё равно блокируется
      final dns = Map<String, dynamic>.from((cfg['dns'] as Map?) ?? const {});
      dns['queryStrategy'] = 'UseIPv4';
      dns.putIfAbsent('servers', () => ['1.1.1.1', '8.8.8.8']);
      cfg['dns'] = dns;
      _blockIpv6FromTun(cfg);
    }
    return jsonEncode(cfg);
  }

  static Map<String, dynamic> _generated(Map<String, dynamic> proxy) => {
        'dns': {
          'servers': ['https+local://1.1.1.1/dns-query', 'localhost'],
          'queryStrategy': 'UseIP',
        },
        'outbounds': [
          proxy,
          {'tag': 'direct', 'protocol': 'freedom'},
          {'tag': 'block', 'protocol': 'blackhole'},
        ],
        'routing': {
          // AsIs: домены не резолвим на телефоне. Иначе правило «блок ::/0»
          // срабатывало на AAAA-записи (у google.com они есть) и рубило сайт.
          'domainStrategy': 'AsIs',
          'rules': [
            {
              'type': 'field',
              'ip': ['geoip:private'],
              'outboundTag': 'direct',
            },
          ],
        },
      };

  /// IPv6 из туннеля блокируем: приложения быстро откатываются на IPv4,
  /// вместо того чтобы зависать на недоступных IPv6-адресах (Telegram и др.).
  static void _blockIpv6FromTun(Map<String, dynamic> cfg) {
    final hasBlock = (cfg['outbounds'] as List)
        .any((o) => o is Map && o['tag'] == 'block');
    if (!hasBlock) {
      (cfg['outbounds'] as List)
          .add({'tag': 'block', 'protocol': 'blackhole'});
    }
    final routing =
        Map<String, dynamic>.from((cfg['routing'] as Map?) ?? const {});
    final rules = List<dynamic>.from((routing['rules'] as List?) ?? const []);
    rules.insert(0, {
      'type': 'field',
      'inboundTag': ['tun'],
      'ip': ['::/0'],
      'outboundTag': 'block',
    });
    routing['rules'] = rules;
    cfg['routing'] = routing;
  }

  static Map<String, dynamic> _deepCopy(Map<String, dynamic> m) =>
      jsonDecode(jsonEncode(m)) as Map<String, dynamic>;
}
