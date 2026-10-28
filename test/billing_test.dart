import 'package:flutter_test/flutter_test.dart';
import 'package:relayfast/src/billing_service.dart';

void main() {
  test('short uuid и адрес прокси из ссылки подписки', () {
    expect(BillingService.shortUuid('https://sub.example.com/AbC123xyz'), 'AbC123xyz');
    expect(BillingService.shortUuid('https://sub.example.com/'), isNull);
    // адрес прокси подставляется при сборке; без него оплата отключена
    final base = BillingService.baseUrl;
    expect(BillingService.baseFor('https://sub.example.com/AbC123xyz'),
        base.isEmpty ? isNull : base);
  });
}
