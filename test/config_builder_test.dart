import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:relayfast/src/models.dart';
import 'package:relayfast/src/xray_config.dart';

const _vlessXhttp =
    'vless://00000000-0000-0000-0000-000000000000@node.example.com:2053'
    '?encryption=none&type=xhttp&path=%2Ffwlink%2F&mode=auto'
    '&extra=%7B%22xmux%22%3A%7B%22maxConcurrency%22%3A%2216-32%22%7D%7D'
    '&security=tls&sni=node.example.com&fp=chrome#NL%201';

const _hy2 = 'hysteria2://secret@hy.example.com:443?sni=hy.example.com&insecure=1#HY%202';

void main() {
  test('parses base64 list of links (vless xhttp + hysteria2)', () {
    final body = base64.encode(utf8.encode('$_vlessXhttp\n$_hy2\nunknown://x\n'));
    final list = SubscriptionParser.parse(body);
    expect(list.map((e) => e.name), ['NL 1', 'HY 2']);

    final v = list[0].outbound!;
    expect(v['protocol'], 'vless');
    expect(v['streamSettings']['network'], 'xhttp');
    expect(v['streamSettings']['xhttpSettings']['path'], '/fwlink/');
    expect(v['streamSettings']['xhttpSettings']['extra']['xmux']['maxConcurrency'],
        '16-32');

    final h = list[1].outbound!;
    expect(h['protocol'], 'hysteria');
    expect(h['streamSettings']['network'], 'hysteria');
    expect(h['streamSettings']['hysteriaSettings']['auth'], 'secret');
    expect(h['streamSettings']['tlsSettings']['allowInsecure'], isTrue);
  });

  test('parses xray-json array and keeps admin routing', () {
    final body = jsonEncode([
      {
        'remarks': 'DE',
        'outbounds': [
          {'tag': 'proxy', 'protocol': 'vless'},
          {'tag': 'direct', 'protocol': 'freedom'},
        ],
        'inbounds': [
          {'protocol': 'socks', 'port': 10808}
        ],
        'routing': {
          'rules': [
            {'type': 'field', 'domain': ['geosite:category-ru'], 'outboundTag': 'direct'}
          ]
        },
      }
    ]);
    final list = SubscriptionParser.parse(body);
    expect(list.single.name, 'DE');
    final cfg = jsonDecode(XrayConfigBuilder.build(list.single)) as Map;
    expect((cfg['inbounds'] as List).single['protocol'], 'tun');
    // Первым идёт правило блокировки IPv6 из туннеля, затем правила админа.
    expect(cfg['routing']['rules'][0]['ip'], ['::/0']);
    expect(cfg['routing']['rules'][1]['outboundTag'], 'direct');
    expect((cfg['inbounds'] as List).single['sniffing']['routeOnly'], isFalse);
    expect(cfg['stats'], isA<Map>());
    expect(cfg['policy']['system']['statsOutboundUplink'], isTrue);

    final ping = jsonDecode(XrayConfigBuilder.build(list.single, tun: false)) as Map;
    expect(ping['inbounds'], isEmpty);
  });

  test('generated config for a link has direct/block and private bypass', () {
    final p = SubscriptionParser.parse(_hy2).single;
    final cfg = jsonDecode(XrayConfigBuilder.build(p)) as Map;
    final tags = (cfg['outbounds'] as List).map((o) => o['tag']).toList();
    expect(tags, ['proxy', 'direct', 'block']);
    expect(cfg['routing']['rules'][0]['ip'], ['::/0']);
    expect(cfg['routing']['rules'][1]['ip'], ['geoip:private']);
  });

  test('shadowsocks both link forms', () {
    final a = base64.encode(utf8.encode('aes-256-gcm:pass'));
    final b = base64.encode(utf8.encode('aes-256-gcm:pass@h.example.com:8388'));
    final l1 = LinkParser.parse('ss://$a@h.example.com:8388#A')!.outbound!;
    final l2 = LinkParser.parse('ss://$b#B')!.outbound!;
    for (final o in [l1, l2]) {
      expect(o['settings']['method'], 'aes-256-gcm');
      expect(o['settings']['password'], 'pass');
      expect(o['settings']['port'], 8388);
    }
  });

  test('duplicate names get suffix; broken entries are skipped', () {
    final body = '$_hy2\n$_hy2\nvless://broken\n';
    final names = SubscriptionParser.parse(body).map((e) => e.name).toList();
    expect(names, ['HY 2', 'HY 2 (2)']);
  });

  test('parses userinfo, duplicated interval and remote config header', () {
    final i = SubscriptionInfo.fromHeaders({
      'subscription-userinfo': 'upload=1; download=2; total=100; expire=1900000000',
      'profile-update-interval': '6, 3',
    });
    expect(i.used, 3);
    expect(i.updateIntervalHours, 6);
    expect(i.expire, isNotNull);

    final raw = 'base64:${base64.encode(utf8.encode(jsonEncode({
          'minBuild': 5,
          'kill': {'enabled': true, 'message': 'x'}
        })))}';
    final r = RemoteConfig.fromHeader(raw)!;
    expect(r.minBuild, 5);
    expect(r.killEnabled, isTrue);
    expect(r.updateRequired(4), isTrue);
  });

  test('saved subscription survives a json round trip', () {
    final sub = SavedSub(
      id: '1',
      url: 'https://sub.example.com/sub/abc',
      raw: 'x',
      info: SubscriptionInfo.fromHeaders({
        'subscription-userinfo': 'upload=1; download=2; total=3; expire=0',
        'profile-title': 'Test',
      }),
    );
    final back = SavedSub.fromJson(jsonDecode(jsonEncode(sub.toJson())) as Map<String, dynamic>);
    expect(back.url, sub.url);
    expect(back.title, 'Test');
    expect(back.info!.total, 3);
  });

  test('server tags show protocol, transport and security', () {
    final p = SubscriptionParser.parse(_hy2).single;
    expect(p.tags.first, isNotEmpty);
  });

  test('xray-json with balancer is marked and keeps balancer in config', () {
    final body = jsonEncode([
      {
        'remarks': '[BR] WiFi | Самые быстрые',
        'outbounds': [
          {
            'tag': 'p1',
            'protocol': 'vless',
            'streamSettings': {'network': 'xhttp', 'security': 'reality'}
          },
          {'tag': 'p2', 'protocol': 'vless'},
          {'tag': 'direct', 'protocol': 'freedom'},
        ],
        'burstObservatory': {'subjectSelector': ['p']},
        'routing': {
          'balancers': [
            {'tag': 'b', 'selector': ['p'], 'strategy': {'type': 'leastPing'}}
          ],
          'rules': [
            {'type': 'field', 'network': 'tcp,udp', 'balancerTag': 'b'}
          ],
        },
      }
    ]);
    final p = SubscriptionParser.parse(body).single;
    expect(p.isBalancer, isTrue);
    expect(p.tags.first, 'БАЛАНСИРОВЩИК');
    expect(p.tags.skip(1), containsAll(['VLESS', 'XHTTP', 'REALITY']));
    final cfg = jsonDecode(XrayConfigBuilder.build(p)) as Map;
    expect(cfg['routing']['balancers'], isNotEmpty);
    expect(cfg['burstObservatory'], isNotNull);
    expect(cfg['routing']['rules'].last['balancerTag'], 'b');
  });
}
