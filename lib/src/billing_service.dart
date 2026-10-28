import 'dart:convert';

import 'package:http/http.dart' as http;

class BillingException implements Exception {
  BillingException(this.message);
  final String message;
  @override
  String toString() => message;
}

class PayMethod {
  PayMethod(this.id, this.title);
  final String id;
  final String title;
}

class Tariff {
  Tariff({
    required this.id,
    required this.name,
    required this.days,
    required this.price,
    required this.currency,
    required this.description,
    this.trafficGb = 0,
    this.limitIp = 0,
  });
  final int id;
  final String name;
  final int days;
  final double price;
  final String currency;
  final String description;
  final int trafficGb;
  final int limitIp;

  /// «5 устр. · 100 ГБ»
  /// Описание тарифа без служебной приписки про конвертацию в TON
  /// (она относится к оплате в крипте, а в приложении оплата только картой/СБП).
  String get cleanDescription {
    var d = description;
    final i = d.indexOf(RegExp(r'Внимание', caseSensitive: false));
    if (i >= 0) d = d.substring(0, i);
    d = d
        .split('\n')
        .where((l) => !RegExp(r'TON|конвертаци', caseSensitive: false).hasMatch(l))
        .join('\n');
    return d.trim();
  }

  /// «5 устр. · 100 ГБ». Если админка не отдала лимиты, берём их из названия
  /// («...+120GB...») и описания («...(3 устройства)»).
  String get details {
    var ip = limitIp;
    var gb = trafficGb;
    if (ip <= 0) {
      final m = RegExp(r'\(\s*(\d+)\s*уст', caseSensitive: false)
              .firstMatch('$name $description') ??
          RegExp(r'(\d+)\s*устр', caseSensitive: false).firstMatch(description);
      ip = int.tryParse(m?.group(1) ?? '') ?? 0;
    }
    if (gb <= 0) {
      final m = RegExp(r'(\d+)\s*(?:GB|ГБ)', caseSensitive: false).firstMatch(name);
      gb = int.tryParse(m?.group(1) ?? '') ?? 0;
    }
    final parts = <String>[];
    if (ip > 0) parts.add('$ip устр.');
    if (gb > 0) parts.add('$gb ГБ');
    return parts.join(' · ');
  }

  String get priceLabel {
    final p = price == price.roundToDouble() ? price.toStringAsFixed(0) : price.toStringAsFixed(2);
    return currency == 'RUB' ? '$p ₽' : '$p $currency';
  }
}

class TariffList {
  TariffList(this.methods, this.method, this.tariffs);
  final List<PayMethod> methods;
  final String method;
  final List<Tariff> tariffs;
}

class PayOrder {
  PayOrder(this.paymentId, this.url);
  final String paymentId;
  final String url;
}

/// Клиент прокси оплаты (`proxy/app_proxy.py`). Секретов здесь нет: прокси
/// сам обращается к боту. Адрес — [baseUrl].
class BillingService {
  BillingService({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;

  /// Короткий uuid — последний сегмент ссылки подписки.
  static String? shortUuid(String subUrl) {
    final u = Uri.tryParse(subUrl);
    if (u == null) return null;
    final segs = u.pathSegments.where((s) => s.isNotEmpty).toList();
    return segs.isEmpty ? null : segs.last;
  }

  /// Адрес прокси оплаты. Подставляется при сборке из секрета GitHub BILLING_URL
  /// (`--dart-define=BILLING_URL=...`), чтобы адрес не лежал в открытом коде.
  static const baseUrl = String.fromEnvironment('BILLING_URL');

  static String? baseFor(String subUrl) => baseUrl.isEmpty ? null : baseUrl;

  Future<Map<String, dynamic>> _call(String method, Uri uri,
      {Object? body, required String sub}) async {
    try {
      // Подписка передаётся заголовком, чтобы не попадать в логи сервера.
      final headers = {'Content-Type': 'application/json', 'X-Sub': sub};
      final r = method == 'POST'
          ? await _client
              .post(uri, headers: headers, body: jsonEncode(body))
              .timeout(const Duration(seconds: 20))
          : await _client.get(uri, headers: headers).timeout(const Duration(seconds: 20));
      Map<String, dynamic> data;
      try {
        data = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
      } catch (_) {
        throw BillingException('Сервис оплаты недоступен (${r.statusCode})');
      }
      if (r.statusCode != 200 || data['ok'] != true) {
        throw BillingException((data['error'] ?? 'Ошибка ${r.statusCode}').toString());
      }
      return data;
    } on BillingException {
      rethrow;
    } catch (_) {
      throw BillingException('Нет связи с сервисом оплаты');
    }
  }

  (String base, String sub) _target(String subUrl) {
    final base = baseFor(subUrl);
    final sub = shortUuid(subUrl);
    if (base == null) {
      throw BillingException('Оплата в этой сборке не настроена');
    }
    if (sub == null) {
      throw BillingException('Оплата доступна только для подписки по ссылке');
    }
    return (base, sub);
  }

  Future<TariffList> tariffs(String subUrl, {String? method}) async {
    final (base, sub) = _target(subUrl);
    final d = await _call('GET',
        Uri.parse('$base/tariffs').replace(queryParameters: {if (method != null) 'method': method}),
        sub: sub);
    final methods = [
      for (final m in (d['methods'] as List? ?? []))
        PayMethod(m['id'].toString(), m['title'].toString())
    ];
    final list = [
      for (final t in (d['tariffs'] as List? ?? []))
        Tariff(
          id: (t['id'] as num).toInt(),
          name: t['name'].toString(),
          days: (t['days'] as num? ?? 0).toInt(),
          price: (t['price'] as num? ?? 0).toDouble(),
          currency: (t['currency'] ?? 'RUB').toString(),
          description: (t['description'] ?? '').toString(),
          trafficGb: (t['traffic_gb'] as num? ?? 0).toInt(),
          limitIp: (t['limit_ip'] as num? ?? 0).toInt(),
        )
    ];
    return TariffList(methods, (d['method'] ?? '').toString(), list);
  }

  Future<PayOrder> pay(String subUrl, int tariffId, String method) async {
    final (base, sub) = _target(subUrl);
    final d = await _call('POST', Uri.parse('$base/pay'),
        body: {'sub': sub, 'tariff_id': tariffId, 'payment_method': method}, sub: sub);
    final url = d['payment_url']?.toString();
    if (url == null || url.isEmpty) throw BillingException('Не получена ссылка на оплату');
    return PayOrder(d['payment_id'].toString(), url);
  }

  /// Статус платежа или null, если его ещё нет в списке.
  Future<String?> status(String subUrl, String paymentId) async {
    final (base, sub) = _target(subUrl);
    final d = await _call('GET', Uri.parse('$base/payments'), sub: sub);
    for (final p in (d['payments'] as List? ?? [])) {
      if (p['payment_id'].toString() == paymentId) return p['status']?.toString();
    }
    return null;
  }
}
