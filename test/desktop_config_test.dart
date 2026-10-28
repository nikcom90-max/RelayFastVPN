import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:relayfast/src/windows/desktop_config.dart';

const _base = '''
{
  "inbounds": [{"tag": "tun", "protocol": "tun"}],
  "outbounds": [
    {"tag": "proxy", "protocol": "vless",
     "settings": {"vnext": [{"address": "node.example.com", "port": 443, "users": []}]}},
    {"tag": "wg", "protocol": "hysteria", "settings": {"address": "203.0.113.7", "port": 443}},
    {"tag": "direct", "protocol": "freedom", "settings": {"address": "ignored.example"}},
    {"tag": "block", "protocol": "blackhole"}
  ],
  "routing": {"rules": [{"type": "field", "ip": ["geoip:private"], "outboundTag": "direct"}]}
}
''';

void main() {
  test('режим прокси: http, socks и api, без tun', () {
    final cfg = jsonDecode(desktopConfig(_base, mode: 'proxy')) as Map<String, dynamic>;
    final tags = [for (final i in cfg['inbounds'] as List) i['tag']];
    expect(tags, ['http-in', 'socks-in', 'api']);
    expect(cfg['api']['services'], contains('StatsService'));
    final first = (cfg['routing']['rules'] as List).first as Map;
    expect(first['inboundTag'], ['api']);
    expect(first['outboundTag'], 'api');
  });

  test('режим tun добавляет адаптер с нужным именем', () {
    final cfg = jsonDecode(desktopConfig(_base, mode: 'tun', adapter: 'RelayFast'))
        as Map<String, dynamic>;
    final tun = (cfg['inbounds'] as List).firstWhere((i) => i['tag'] == 'tun') as Map;
    expect(tun['protocol'], 'tun');
    expect(tun['settings']['name'], 'RelayFast');
  });

  test('конфиг для проверки задержки: один http-inbound на нужном порту', () {
    final cfg = jsonDecode(pingConfig(_base, 12345)) as Map<String, dynamic>;
    final inbounds = cfg['inbounds'] as List;
    expect(inbounds.length, 1);
    expect(inbounds.first['port'], 12345);
    expect(cfg.containsKey('api'), isFalse);
  });

  test('адреса серверов собираются без freedom и blackhole', () {
    final hosts = serverHosts(_base)..sort();
    expect(hosts, ['203.0.113.7', 'node.example.com']);
  });
}
