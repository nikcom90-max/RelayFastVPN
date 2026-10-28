import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app.dart' show brandPurple;
import '../app_state.dart';
import '../models.dart';
import '../vpn_engine.dart';
import '../xray_config.dart';
import 'qr_screen.dart';
import 'settings_screen.dart';

/// Главный экран в стиле INCY: кнопка, баннер, подписка и сразу список серверов.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final scheme = Theme.of(context).colorScheme;
    final info = c.info;
    final banner = c.remote.notice ?? info?.announce;

    final String label;
    switch (c.status.state) {
      case EngineState.started:
        label = 'Подключено';
      case EngineState.starting:
        label = 'Подключение…';
      case EngineState.stopping:
        label = 'Отключение…';
      default:
        label = 'Нажмите для подключения';
    }

    return Scaffold(
      appBar: AppBar(
        title: Row(mainAxisSize: MainAxisSize.min, children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.asset('assets/logo.jpg', width: 28, height: 28),
          ),
          const SizedBox(width: 10),
          Text(c.brandName),
        ]),
        actions: [
          IconButton(
            tooltip: 'Настройки',
            icon: const Icon(Icons.tune),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => SettingsScreen(controller: c))),
          ),
          IconButton(
            icon: const Icon(Icons.more_vert),
            onPressed: () => _menu(context),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _manualRefresh(context),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          children: [
            if (c.update != null)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.system_update),
                  title: Text('Доступно обновление (сборка ${c.update!.build})'),
                  subtitle: c.updateProgress != null
                      ? LinearProgressIndicator(value: c.updateProgress)
                      : (c.updateMessage != null ? Text(c.updateMessage!) : null),
                  trailing: TextButton(
                    onPressed: c.updateProgress != null ? null : c.installUpdate,
                    child: const Text('Установить'),
                  ),
                ),
              ),
            const SizedBox(height: 12),
            Center(child: _PowerButton(controller: c)),
            const SizedBox(height: 14),
            Center(
              child: Text(label,
                  style: TextStyle(
                      color: c.connected ? scheme.primary : scheme.onSurfaceVariant,
                      fontSize: 15)),
            ),
            if (c.connected) _TrafficPanel(controller: c),
            if (c.connected)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Center(
                  child: TextButton.icon(
                    icon: c.checking
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.network_check, size: 18),
                    label: const Text('Проверить соединение'),
                    onPressed: c.checking ? null : () => _check(context),
                  ),
                ),
              ),
            if (c.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Center(
                  child: Text(c.error!,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.error)),
                ),
              ),
            const SizedBox(height: 16),
            if (banner != null) _Banner(icon: Icons.notifications_none, text: banner),
            if (c.remote.updateAvailable(c.build) && c.remote.updateUrl != null)
              _Banner(
                icon: Icons.system_update_alt,
                text: 'Доступно обновление'
                    '${c.remote.updateNotes == null ? '' : ': ${c.remote.updateNotes}'}',
                onTap: () => launchUrl(Uri.parse(c.remote.updateUrl!),
                    mode: LaunchMode.externalApplication),
              ),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Добавить'),
                  onPressed: () => _addDialog(context),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.content_paste, size: 18),
                  label: const Text('Вставить'),
                  onPressed: () => _paste(context),
                ),
              ),
              if (!Platform.isWindows) ...[
                const SizedBox(width: 10),
                IconButton.outlined(
                  tooltip: 'Сканировать QR-код',
                  icon: const Icon(Icons.qr_code_scanner),
                  onPressed: () => _scan(context),
                ),
              ],
            ]),
            const SizedBox(height: 18),
            Text('ТЕКУЩАЯ ПОДПИСКА',
                style: TextStyle(
                    fontSize: 11, letterSpacing: 1, color: scheme.onSurfaceVariant)),
            const SizedBox(height: 8),
            _SubscriptionCard(controller: c, onRefresh: () => _manualRefresh(context)),
            const SizedBox(height: 10),
            _AutoTile(controller: c),
            for (final s in c.servers) _ServerTile(controller: c, server: s),
          ],
        ),
      ),
    );
  }

  Future<void> _manualRefresh(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await controller.refresh();
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
      content: Text(ok
          ? 'Подписка обновлена: серверов ${controller.servers.length}'
          : (controller.error ?? 'Не удалось обновить подписку')),
    ));
  }

  Future<void> _importText(BuildContext context, String text) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await controller.importSubscription(text);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
        content: Text(ok
            ? 'Подписка добавлена: серверов ${controller.servers.length}'
            : (controller.error ?? 'Не удалось добавить подписку'))));
  }

  Future<void> _paste(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final d = await Clipboard.getData(Clipboard.kTextPlain);
    final text = d?.text?.trim();
    if (text == null || text.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('Буфер обмена пуст')));
      return;
    }
    if (!context.mounted) return;
    await _importText(context, text);
  }

  Future<void> _scan(BuildContext context) async {
    final code = await Navigator.of(context)
        .push<String>(MaterialPageRoute(builder: (_) => const QrScreen()));
    if (code == null || !context.mounted) return;
    await _importText(context, code);
  }

  Future<void> _check(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final ms = await controller.checkConnection();
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
        content: Text(ms >= 0
            ? 'Соединение работает: $ms мс'
            : 'Нет ответа через VPN. Попробуйте другой сервер.')));
  }

  Future<void> _addDialog(BuildContext context) async {
    final text = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Ссылка подписки'),
        content: TextField(
          controller: text,
          autofocus: true,
          minLines: 1,
          maxLines: 3,
          decoration: const InputDecoration(hintText: 'https://…/sub/…'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(100, 40)),
            onPressed: () => Navigator.pop(ctx, text.text.trim()),
            child: const Text('Добавить'),
          ),
        ],
      ),
    );
    if (url == null || url.isEmpty || !context.mounted) return;
    await _importText(context, url);
  }

  void _menu(BuildContext context) {
    final c = controller;
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (c.remote.botUrl != null)
            ListTile(
              leading: const Icon(Icons.chat_outlined),
              title: const Text('Бот (оплата, продление)'),
              onTap: () => launchUrl(Uri.parse(c.remote.botUrl!),
                  mode: LaunchMode.externalApplication),
            ),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('Удалить текущую подписку'),
            onTap: () {
              Navigator.pop(ctx);
              c.removeActiveSub();
            },
          ),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: Text('Версия ${c.appVersion} (${c.build})'),
          ),
        ]),
      ),
    );
  }
}

class _PowerButton extends StatelessWidget {
  const _PowerButton({required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final scheme = Theme.of(context).colorScheme;
    return RepaintBoundary(
      child: GestureDetector(
      onTap: c.busy ? null : c.toggle,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        width: 132,
        height: 132,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: c.connected
              ? LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [scheme.primary, brandPurple])
              : null,
          color: c.connected ? null : scheme.surfaceContainer,
          border: Border.all(
              color: scheme.primary.withOpacity(c.connected ? 0 : .35), width: 3),
          boxShadow: c.connected
              ? [BoxShadow(color: scheme.primary.withOpacity(.4), blurRadius: 24)]
              : null,
        ),
        child: c.busy
            ? const Padding(
                padding: EdgeInsets.all(46),
                child: CircularProgressIndicator(strokeWidth: 3))
            : Icon(Icons.power_settings_new,
                size: 60, color: c.connected ? scheme.surface : scheme.primary),
      ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.text, this.onTap});
  final IconData icon;
  final String text;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: scheme.primary.withOpacity(.08),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: scheme.primary.withOpacity(.25)),
          ),
          child: Row(children: [
            Icon(icon, size: 18, color: scheme.primary),
            const SizedBox(width: 10),
            Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
          ]),
        ),
      ),
    );
  }
}

class _SubscriptionCard extends StatelessWidget {
  const _SubscriptionCard({required this.controller, required this.onRefresh});
  final AppController controller;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final info = c.info;
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(fontSize: 12, color: scheme.onSurfaceVariant);
    final site = c.info?.webPageUrl;
    final support = c.remote.supportUrl ?? info?.supportUrl;

    String left = '';
    if (info?.expire != null) {
      final d = info!.expire!.difference(DateTime.now()).inDays;
      left = info.expired ? 'Подписка истекла' : 'Осталось $d д';
    } else if (info != null) {
      left = 'Без срока действия';
    }

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: c.subs.length > 1
                  ? PopupMenuButton<String>(
                      tooltip: 'Сменить подписку',
                      onSelected: c.switchSub,
                      itemBuilder: (_) => [
                        for (final sub in c.subs)
                          PopupMenuItem(
                            value: sub.id,
                            child: Text(sub.title,
                                style: TextStyle(
                                    fontWeight: sub.id == c.active?.id
                                        ? FontWeight.w700
                                        : FontWeight.w400)),
                          ),
                      ],
                      child: Row(children: [
                        Flexible(
                          child: Text(c.active?.title ?? c.brandName,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600, fontSize: 15)),
                        ),
                        const Icon(Icons.arrow_drop_down),
                      ]),
                    )
                  : Text(c.active?.title ?? c.brandName,
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
            ),
            IconButton(
              tooltip: 'Обновить подписку',
              visualDensity: VisualDensity.compact,
              icon: c.refreshing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh, size: 20),
              onPressed: c.refreshing ? null : onRefresh,
            ),
            IconButton(
              tooltip: 'Проверить задержки',
              visualDensity: VisualDensity.compact,
              icon: c.pinging
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.speed, size: 20),
              onPressed: c.pinging ? null : c.testDelays,
            ),
          ]),
          if (info != null) ...[
            Row(children: [
              Text(left, style: muted),
              const Spacer(),
              Text(
                  info.unlimited
                      ? '${formatBytes(info.used)} · безлимит'
                      : '${formatBytes(info.used)} / ${formatBytes(info.total)}',
                  style: muted),
            ]),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                minHeight: 6,
                value: info.unlimited ? 1 : (1 - info.used / info.total).clamp(0.0, 1.0),
                backgroundColor: scheme.surfaceContainerHighest,
              ),
            ),
          ],
          if (c.subUrl != null) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                icon: const Icon(Icons.add_card, size: 18),
                label: Text(info?.expired == true ? 'Продлить подписку' : 'Продлить'),
                onPressed: () => c.tab.value = 1,
              ),
            ),
          ],
          if (site != null || support != null) ...[
            const SizedBox(height: 10),
            Wrap(spacing: 8, children: [
              if (site != null)
                ActionChip(
                  avatar: const Icon(Icons.language, size: 16),
                  label: const Text('Сайт'),
                  onPressed: () => launchUrl(Uri.parse(site),
                      mode: LaunchMode.externalApplication),
                ),
              if (support != null)
                ActionChip(
                  avatar: const Icon(Icons.support_agent, size: 16),
                  label: const Text('Поддержка'),
                  onPressed: () => launchUrl(Uri.parse(support),
                      mode: LaunchMode.externalApplication),
                ),
            ]),
          ],
        ]),
      ),
    );
  }
}

class _ServerTile extends StatelessWidget {
  const _ServerTile({required this.controller, required this.server});
  final AppController controller;
  final ServerProfile server;

  static final _emojiFlag = RegExp('[\u{1F1E6}-\u{1F1FF}]{2}', unicode: true);

  /// Делит название на код страны и текст. Флаг рисуется картинкой из
  /// assets/flags (эмодзи-флаги Windows не умеет показывать — там вместо них
  /// видны буквы «FI», «NL»). Код берётся из эмодзи-флага в названии (его
  /// отдаёт Ремна) или из двухбуквенного префикса «FI …». Названия вида
  /// «[BR] …» (метка бренда) флагом не дополняются.
  static ({String? code, String text}) _split(String name, {bool balancer = false}) {
    final n = name.trim();
    final m = _emojiFlag.firstMatch(n);
    if (m != null) {
      final code = String.fromCharCodes(
          m.group(0)!.runes.map((r) => 0x41 + r - 0x1F1E6));
      final rest =
          n.replaceAll(_emojiFlag, '').replaceAll(RegExp(r'\s{2,}'), ' ').trim();
      return (code: code, text: rest.isEmpty ? n : rest);
    }
    final p = RegExp(r'^[#_ ]*([A-Za-z]{2})(?![A-Za-z])').firstMatch(n);
    if (p != null) {
      final raw = p.group(1)!;
      if (raw == raw.toUpperCase()) {
        final code = const {'SW': 'SE', 'UK': 'GB'}[raw] ?? raw;
        return (code: code, text: n);
      }
    }
    return (code: null, text: balancer ? '⚡ $n' : n);
  }

  static Widget _flag(String code) => Padding(
        padding: const EdgeInsets.only(right: 10),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: Image.asset(
            'assets/flags/${code.toLowerCase()}.png',
            width: 26,
            height: 19,
            fit: BoxFit.cover,
            filterQuality: FilterQuality.medium,
            errorBuilder: (_, __, ___) => const SizedBox(width: 26, height: 19),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final scheme = Theme.of(context).colorScheme;
    final sel = c.selectedProfile?.name == server.name &&
        (!c.settings.autoServer || c.connected);
    final ms = c.delays[server.name];
    final tags = server.tags;
    final parts = _split(server.name, balancer: server.isBalancer);

    Widget ping;
    if (c.testing.contains(server.name)) {
      ping = const SizedBox(
          width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2));
    } else if (ms == null) {
      ping = Icon(Icons.network_ping, size: 20, color: scheme.onSurfaceVariant);
    } else if (ms < 0) {
      ping = Text('n/a', style: TextStyle(color: scheme.error, fontSize: 12));
    } else {
      final color = ms < 100
          ? const Color(0xFF3DDC84)
          : ms < 250
              ? const Color(0xFFFFC145)
              : const Color(0xFFFF6B5E);
      ping = Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text('$ms мс', style: const TextStyle(fontSize: 12)),
      ]);
    }

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => c.selectServer(server.name),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: sel ? scheme.primary.withOpacity(.12) : scheme.surfaceContainer,
            border: Border.all(
                color: sel ? scheme.primary : scheme.primary.withOpacity(.12),
                width: sel ? 1.5 : 1),
          ),
          child: Row(children: [
            if (parts.code != null) _flag(parts.code!),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(parts.text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w500)),
                if (tags.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Row(children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                          color: scheme.primary.withOpacity(.2),
                          borderRadius: BorderRadius.circular(4)),
                      child: Text(tags.first,
                          style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: scheme.primary)),
                    ),
                    if (tags.length > 1)
                      Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: Text(tags.skip(1).join(' · '),
                            style: TextStyle(
                                fontSize: 10, color: scheme.onSurfaceVariant)),
                      ),
                  ]),
                ],
              ]),
            ),
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => c.testOne(server.name),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: ping,
              ),
            ),
          ]),
        ),
      ),
    );
  }
}


class _AutoTile extends StatelessWidget {
  const _AutoTile({required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final scheme = Theme.of(context).colorScheme;
    final on = c.settings.autoServer;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => c.updateSettings((s) => s.autoServer = !s.autoServer),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: on ? scheme.primary.withOpacity(.12) : scheme.surfaceContainer,
            border: Border.all(
                color: on ? scheme.primary : scheme.primary.withOpacity(.12),
                width: on ? 1.5 : 1),
          ),
          child: Row(children: [
            Icon(Icons.auto_awesome, color: scheme.primary, size: 22),
            const SizedBox(width: 12),
            const Expanded(
              child: Text('Авто · самый быстрый сервер',
                  style: TextStyle(fontWeight: FontWeight.w500)),
            ),
            Icon(on ? Icons.check_circle : Icons.circle_outlined,
                color: on ? scheme.primary : scheme.onSurfaceVariant, size: 20),
          ]),
        ),
      ),
    );
  }
}


/// Текущая скорость и трафик: за этот сеанс и всего через приложение.
class _TrafficPanel extends StatelessWidget {
  const _TrafficPanel({required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(fontSize: 12, color: scheme.onSurfaceVariant);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(children: [
        ValueListenableBuilder<({int up, int down})>(
          valueListenable: controller.speed,
          builder: (context, v, _) => Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _SpeedItem(
                  icon: Icons.arrow_downward,
                  color: scheme.primary,
                  value: '${formatBytes(v.down)}/с'),
              const SizedBox(width: 28),
              _SpeedItem(
                  icon: Icons.arrow_upward,
                  color: brandPurple,
                  value: '${formatBytes(v.up)}/с'),
            ],
          ),
        ),
        const SizedBox(height: 6),
        ValueListenableBuilder<TrafficStats>(
          valueListenable: controller.traffic,
          builder: (context, t, _) => Column(children: [
            Text(
                'За сеанс: ↓ ${formatBytes(t.sessionDown)}   ↑ ${formatBytes(t.sessionUp)}',
                style: muted),
            const SizedBox(height: 2),
            Text(
                'Всего через приложение: ${formatBytes(t.totalDown + t.totalUp)}',
                style: muted),
          ]),
        ),
      ]),
    );
  }
}

class _SpeedItem extends StatelessWidget {
  const _SpeedItem({required this.icon, required this.color, required this.value});
  final IconData icon;
  final Color color;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 18, color: color),
      const SizedBox(width: 4),
      Text(value, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
    ]);
  }
}
