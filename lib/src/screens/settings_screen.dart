import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../models.dart';
import '../settings.dart';
import '../update_service.dart';
import '../xray_config.dart';
import 'apps_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.controller});
  final AppController controller;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _url =
      TextEditingController(text: widget.controller.settings.pingUrl);

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final s = c.settings;
        return Scaffold(
          appBar: AppBar(title: const Text('Настройки')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const _Section('Оформление'),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'dark', label: Text('Тёмная')),
                  ButtonSegment(value: 'light', label: Text('Светлая')),
                  ButtonSegment(value: 'system', label: Text('Как в системе')),
                ],
                selected: {s.theme},
                onSelectionChanged: (v) => c.updateSettings((x) => x.theme = v.first),
              ),
              const SizedBox(height: 20),
              const _Section('Подключение'),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Автовыбор сервера'),
                subtitle: const Text(
                    'При подключении проверяются все серверы, берётся самый '
                    'быстрый. Если не вышло, пробуются следующие.'),
                value: s.autoServer,
                onChanged: (v) => c.updateSettings((x) => x.autoServer = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Поднимать VPN после сна'),
                subtitle: const Text(
                    'Если система отключила VPN, пока экран был выключен, '
                    'при возвращении в приложение он включится сам.'),
                value: s.autoReconnect,
                onChanged: (v) => c.updateSettings((x) => x.autoReconnect = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Подключаться при запуске'),
                value: s.autoConnect,
                onChanged: (v) => c.updateSettings((x) => x.autoConnect = v),
              ),
              const SizedBox(height: 12),
              if (Platform.isWindows) ...[
                const _Section('Режим VPN'),
                RadioGroup<String>(
                  groupValue: s.desktopMode,
                  onChanged: (v) {
                    if (v != null) c.updateSettings((x) => x.desktopMode = v);
                  },
                  child: const Column(children: [
                    RadioListTile<String>(
                      contentPadding: EdgeInsets.zero,
                      value: 'proxy',
                      title: Text('Системный прокси'),
                      subtitle: Text(
                          'Без прав администратора. Подходит для браузеров и большинства программ.'),
                    ),
                    RadioListTile<String>(
                      contentPadding: EdgeInsets.zero,
                      value: 'tun',
                      title: Text('TUN: весь трафик (бета)'),
                      subtitle: Text(
                          'Все программы и игры через VPN. Нужен запуск от имени администратора.'),
                    ),
                  ]),
                ),
                if (s.desktopMode == 'tun')
                  FutureBuilder<bool>(
                    future: c.isElevated(),
                    builder: (context, snap) {
                      if (snap.data != false) return const SizedBox.shrink();
                      return Card(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                  'Приложение запущено без прав администратора, поэтому TUN не включится.'),
                              const SizedBox(height: 8),
                              FilledButton(
                                onPressed: c.relaunchElevated,
                                child: const Text('Перезапустить от имени администратора'),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                if (c.connected)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('Изменения применятся после переподключения.',
                        style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context).colorScheme.onSurfaceVariant)),
                  ),
              ] else ...[
              const _Section('Работа в фоне'),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.battery_saver),
                title: const Text('Не ограничивать в фоне'),
                subtitle: const Text(
                    'Разрешите приложению работать без ограничений батареи, '
                    'иначе система может отключать VPN при долгом сне экрана.'),
                onTap: c.requestIgnoreBattery,
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.shield_outlined),
                title: const Text('Постоянный VPN (Always-on)'),
                subtitle: const Text(
                    'В системных настройках выберите RelayFastVPN и включите '
                    '«Постоянный VPN»: Android сам поднимет его после сна и перезагрузки.'),
                onTap: c.openVpnSettings,
              ),
              const SizedBox(height: 12),
              const _Section('Раздельное туннелирование'),
              RadioGroup<String>(
                groupValue: s.splitMode,
                onChanged: (v) {
                  if (v != null) c.updateSettings((x) => x.splitMode = v);
                },
                child: const Column(children: [
                  RadioListTile<String>(
                    contentPadding: EdgeInsets.zero,
                    value: 'off',
                    title: Text('Все приложения через VPN'),
                  ),
                  RadioListTile<String>(
                    contentPadding: EdgeInsets.zero,
                    value: 'bypass',
                    title: Text('Выбранные приложения мимо VPN'),
                    subtitle: Text('Например, банки и Госуслуги'),
                  ),
                  RadioListTile<String>(
                    contentPadding: EdgeInsets.zero,
                    value: 'only',
                    title: Text('Через VPN только выбранные'),
                  ),
                ]),
              ),
              if (s.splitMode != 'off')
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.apps),
                  title: const Text('Выбрать приложения'),
                  subtitle: Text('Выбрано: ${s.splitApps.length}'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => AppsScreen(controller: c))),
                ),
              if (c.connected)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                      'Изменения применятся после переподключения.',
                      style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onSurfaceVariant)),
                ),
              ],
              const SizedBox(height: 20),
              const _Section('Проверка соединения'),
              TextField(
                controller: _url,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  labelText: 'Адрес для проверки (GET)',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    tooltip: 'По умолчанию',
                    icon: const Icon(Icons.restore),
                    onPressed: () {
                      _url.text = defaultPingUrl;
                      c.updateSettings((x) => x.pingUrl = defaultPingUrl);
                    },
                  ),
                ),
                onSubmitted: (v) {
                  final t = v.trim();
                  final u = Uri.tryParse(t);
                  if (u != null && (u.scheme == 'http' || u.scheme == 'https') &&
                      u.host.isNotEmpty) {
                    c.updateSettings((x) => x.pingUrl = t);
                  } else {
                    _url.text = s.pingUrl;
                  }
                },
              ),
              const SizedBox(height: 4),
              Text('Нажмите «Готово» на клавиатуре, чтобы сохранить.',
                  style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant)),
              const SizedBox(height: 20),
              const _Section('Трафик'),
              ValueListenableBuilder<TrafficStats>(
                valueListenable: c.traffic,
                builder: (context, t, _) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.data_usage),
                  title: Text(
                      'Всего через приложение: ${formatBytes(t.totalDown + t.totalUp)}'),
                  subtitle: Text(
                      '↓ ${formatBytes(t.totalDown)}   ↑ ${formatBytes(t.totalUp)}'),
                  trailing: TextButton(
                    onPressed: c.resetTotalTraffic,
                    child: const Text('Сбросить'),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              if (UpdateService.enabled) ...[
                const _Section('Обновления'),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(c.update != null
                      ? Icons.system_update
                      : Icons.check_circle_outline),
                  title: Text(c.update != null
                      ? 'Доступна новая версия (сборка ${c.update!.build})'
                      : 'Версия ${c.appVersion} (${c.build})'),
                  subtitle: c.updateProgress != null
                      ? Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: LinearProgressIndicator(value: c.updateProgress))
                      : (c.updateMessage != null ? Text(c.updateMessage!) : null),
                  trailing: c.update != null
                      ? FilledButton(
                          style: FilledButton.styleFrom(
                              minimumSize: const Size(0, 40)),
                          onPressed:
                              c.updateProgress != null ? null : c.installUpdate,
                          child: const Text('Установить'),
                        )
                      : TextButton(
                          onPressed: c.checkingUpdate
                              ? null
                              : () => c.checkUpdate(manual: true),
                          child: Text(c.checkingUpdate ? 'Проверяю…' : 'Проверить'),
                        ),
                ),
                const SizedBox(height: 12),
              ],
              const _Section('Диагностика'),
              SelectableText(c.subscriptionDiagnostics,
                  style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant)),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('Скопировать конфиг без ключей'),
                  onPressed: () {
                    final p = c.selectedProfile;
                    String text;
                    if (p == null) {
                      text = 'Сервер не выбран';
                    } else {
                      try {
                        final m = jsonDecode(XrayConfigBuilder.build(p))
                            as Map<String, dynamic>;
                        // outbound-ы оставляем без адресов и ключей
                        m['outbounds'] = (m['outbounds'] as List)
                            .map((o) => {
                                  'tag': (o as Map)['tag'],
                                  'protocol': o['protocol'],
                                  'network': (o['streamSettings'] as Map?)?['network'],
                                  'security': (o['streamSettings'] as Map?)?['security'],
                                })
                            .toList();
                        text = const JsonEncoder.withIndent(' ').convert(m);
                      } catch (e) {
                        text = 'Ошибка: $e';
                      }
                    }
                    Clipboard.setData(ClipboardData(text: text));
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Скопировано')));
                  },
                ),
              ),
              const SizedBox(height: 24),
              Center(
                child: Text('Версия ${c.appVersion} (${c.build})',
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text.toUpperCase(),
            style: TextStyle(
                fontSize: 11,
                letterSpacing: 1,
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
      );
}
