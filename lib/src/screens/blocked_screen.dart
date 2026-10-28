import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';

/// Блокирующий экран: аварийное отключение (kill-switch) или обязательное
/// обновление. Управляется заголовком `x-relayfast-config` из Remnawave.
class BlockedScreen extends StatelessWidget {
  const BlockedScreen({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final kill = c.blockReason == BlockReason.kill;
    final r = c.remote;
    final url = kill ? (r.supportUrl ?? r.botUrl) : r.updateUrl;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(kill ? Icons.block : Icons.system_update,
                  size: 72, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 16),
              Text(kill ? 'Сервис временно недоступен' : 'Нужно обновить приложение',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 12),
              Text(
                kill
                    ? (r.killMessage ?? 'Попробуйте позже или напишите в поддержку.')
                    : (r.updateNotes ??
                        'Эта версия больше не поддерживается. Установите новую.'),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              if (url != null)
                FilledButton(
                  onPressed: () =>
                      launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
                  child: Text(kill ? 'Поддержка' : 'Скачать обновление'),
                ),
              TextButton(
                onPressed: () => c.refresh(),
                child: const Text('Проверить снова'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
