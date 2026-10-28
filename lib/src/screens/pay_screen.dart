import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../billing_service.dart';

/// «Продлить подписку»: тарифы из бота → оплата в браузере → подписка
/// обновляется сама, когда платёж прошёл.
class PayScreen extends StatefulWidget {
  const PayScreen({super.key, required this.controller});
  final AppController controller;

  @override
  State<PayScreen> createState() => _PayScreenState();
}

enum _Phase { choose, waiting, done, failed }

class _PayScreenState extends State<PayScreen> with WidgetsBindingObserver {
  final _billing = BillingService();
  TariffList? _data;
  String? _error;
  bool _loading = true;
  bool _creating = false;
  String? _method;
  int? _days; // выбранный срок
  _Phase _phase = _Phase.choose;
  String? _paymentId;
  Timer? _poll;
  int _polls = 0;

  String get _subUrl => widget.controller.subUrl ?? '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // вернулись из браузера — сразу проверяем платёж
    if (state == AppLifecycleState.resumed && _phase == _Phase.waiting) _check();
  }

  Future<void> _load({String? method}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final d = await _billing.tariffs(_subUrl, method: method ?? _method);
      if (!mounted) return;
      setState(() {
        _data = d;
        _method = d.method;
        final ds = d.tariffs.map((t) => t.days).toSet();
        if (_days == null || !ds.contains(_days)) {
          _days = ds.isEmpty ? null : (ds.contains(30) ? 30 : (ds.toList()..sort()).first);
        }
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _buy(Tariff t) async {
    if (_creating || _method == null) return;
    setState(() => _creating = true);
    try {
      final order = await _billing.pay(_subUrl, t.id, _method!);
      _paymentId = order.paymentId;
      final ok = await launchUrl(Uri.parse(order.url),
          mode: Platform.isWindows
              ? LaunchMode.externalApplication
              : LaunchMode.inAppBrowserView);
      if (!ok) {
        await launchUrl(Uri.parse(order.url), mode: LaunchMode.externalApplication);
      }
      if (!mounted) return;
      setState(() {
        _phase = _Phase.waiting;
        _creating = false;
      });
      _startPolling();
    } catch (e) {
      if (!mounted) return;
      setState(() => _creating = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  void _startPolling() {
    _poll?.cancel();
    _polls = 0;
    _poll = Timer.periodic(const Duration(seconds: 6), (_) {
      // платёж ждём максимум ~15 минут
      if (++_polls > 150) {
        _poll?.cancel();
        return;
      }
      _check();
    });
  }

  Future<void> _check() async {
    final id = _paymentId;
    if (id == null || _phase != _Phase.waiting) return;
    try {
      final st = await _billing.status(_subUrl, id);
      if (!mounted) return;
      if (st == 'succeeded' || st == 'paid' || st == 'success') {
        _poll?.cancel();
        setState(() => _phase = _Phase.done);
        await widget.controller.refresh();
      } else if (st == 'canceled' || st == 'cancelled' || st == 'failed' || st == 'expired') {
        _poll?.cancel();
        setState(() => _phase = _Phase.failed);
      }
    } catch (_) {
      // сеть моргнула — попробуем на следующем тике
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Оплата')),
      body: SafeArea(child: _body(context)),
    );
  }

  Widget _body(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    switch (_phase) {
      case _Phase.waiting:
        return _Status(
          icon: const SizedBox(width: 48, height: 48, child: CircularProgressIndicator()),
          title: 'Ждём оплату',
          text: 'Оплатите в открывшемся окне. Как только платёж пройдёт, подписка '
              'обновится сама.',
          actions: [
            FilledButton(onPressed: _check, child: const Text('Проверить оплату')),
            TextButton(
              onPressed: () {
                _poll?.cancel();
                setState(() => _phase = _Phase.choose);
              },
              child: const Text('Назад к тарифам'),
            ),
          ],
        );
      case _Phase.done:
        return _Status(
          icon: Icon(Icons.check_circle, size: 64, color: scheme.primary),
          title: 'Оплата прошла',
          text: 'Подписка продлена и обновлена.',
          actions: [
            FilledButton(
              onPressed: () {
                setState(() => _phase = _Phase.choose);
                widget.controller.tab.value = 0;
              },
              child: const Text('Готово'),
            ),
          ],
        );
      case _Phase.failed:
        return _Status(
          icon: Icon(Icons.error_outline, size: 64, color: scheme.error),
          title: 'Платёж не прошёл',
          text: 'Платёж отменён или истёк. Попробуйте ещё раз.',
          actions: [
            FilledButton(
              onPressed: () => setState(() => _phase = _Phase.choose),
              child: const Text('К тарифам'),
            ),
          ],
        );
      case _Phase.choose:
        break;
    }

    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null || _data == null) {
      return _Status(
        icon: Icon(Icons.cloud_off, size: 56, color: scheme.error),
        title: 'Не удалось загрузить тарифы',
        text: _error ?? '',
        actions: [FilledButton(onPressed: _load, child: const Text('Повторить'))],
      );
    }

    final d = _data!;
    final info = widget.controller.info;
    String left = '';
    if (info?.expire != null) {
      final days = info!.expire!.difference(DateTime.now()).inDays;
      left = info.expired
          ? 'Подписка истекла'
          : 'Подписка активна: осталось $days дн.';
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (left.isNotEmpty)
          Card(
            margin: const EdgeInsets.only(bottom: 14),
            child: ListTile(
              leading: Icon(
                  info?.expired == true ? Icons.warning_amber : Icons.verified_outlined,
                  color: info?.expired == true ? scheme.error : scheme.primary),
              title: Text(left),
              subtitle: const Text('Оплата продлевает текущую подписку'),
            ),
          ),
        if (d.methods.length > 1) ...[
          Wrap(spacing: 8, children: [
            for (final m in d.methods)
              ChoiceChip(
                label: Text(m.title),
                selected: m.id == _method,
                onSelected: (_) => _load(method: m.id),
              ),
          ]),
          const SizedBox(height: 12),
        ],
        if (d.tariffs.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text('Нет доступных тарифов для этого способа оплаты.',
                textAlign: TextAlign.center),
          ),
        if (d.tariffs.isNotEmpty) ...[
          Wrap(spacing: 8, children: [
            for (final days in (d.tariffs.map((t) => t.days).toSet().toList()..sort()))
              ChoiceChip(
                label: Text('$days дн.'),
                selected: days == _days,
                onSelected: (_) => setState(() => _days = days),
              ),
          ]),
          const SizedBox(height: 12),
        ],
        for (final t in d.tariffs.where((t) => t.days == _days))
          Card(
            margin: const EdgeInsets.only(bottom: 10),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(t.name,
                          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                      const SizedBox(height: 4),
                      Text(
                        t.details.isNotEmpty
                            ? t.details
                            : (t.cleanDescription.isNotEmpty
                                ? t.cleanDescription
                                : '${t.days} дн.'),
                        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                // В теме у FilledButton минимальная ширина «на всю строку»,
                // поэтому здесь задаём свою, иначе кнопка сжимает название.
                FilledButton(
                  style: FilledButton.styleFrom(minimumSize: const Size(96, 44)),
                  onPressed: _creating ? null : () => _buy(t),
                  child: Text(t.priceLabel),
                ),
              ]),
            ),
          ),
        const SizedBox(height: 8),
        Text(
          'Оплата проходит в защищённом окне платёжного сервиса. '
          'Данные карты приложение не получает.',
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

class _Status extends StatelessWidget {
  const _Status({required this.icon, required this.title, required this.text, required this.actions});
  final Widget icon;
  final String title;
  final String text;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          icon,
          const SizedBox(height: 16),
          Text(title, style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
          if (text.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(text, textAlign: TextAlign.center),
          ],
          const SizedBox(height: 20),
          ...actions,
        ]),
      ),
    );
  }
}
