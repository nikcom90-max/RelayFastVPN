import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import 'qr_screen.dart';

class ImportScreen extends StatefulWidget {
  const ImportScreen({super.key, required this.controller});
  final AppController controller;

  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends State<ImportScreen> {
  final _text = TextEditingController();

  Future<void> _paste() async {
    final d = await Clipboard.getData(Clipboard.kTextPlain);
    if (d?.text != null) setState(() => _text.text = d!.text!.trim());
  }

  Future<void> _scan() async {
    final code = await Navigator.of(context)
        .push<String>(MaterialPageRoute(builder: (_) => const QrScreen()));
    if (code == null || !mounted) return;
    setState(() => _text.text = code);
    await widget.controller.importSubscription(code);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Center(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(28),
                  child: Image.asset('assets/logo.jpg', width: 150, height: 150),
                ),
              ),
              const SizedBox(height: 16),
              Center(
                child: Text(c.brandName,
                    style: Theme.of(context).textTheme.headlineMedium),
              ),
              const SizedBox(height: 12),
              const Text(
                  'Вставьте ссылку подписки, которую выдал бот. '
                  'Или нажмите кнопку «Открыть в приложении» в боте.'),
              const SizedBox(height: 24),
              TextField(
                controller: _text,
                minLines: 1,
                maxLines: 3,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  hintText: 'https://…/sub/…',
                  suffixIcon: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!Platform.isWindows)
                        IconButton(
                          tooltip: 'Сканировать QR-код',
                          icon: const Icon(Icons.qr_code_scanner),
                          onPressed: _scan,
                        ),
                      IconButton(
                        tooltip: 'Вставить',
                        icon: const Icon(Icons.content_paste),
                        onPressed: _paste,
                      ),
                    ],
                  ),
                ),
              ),
              if (c.error != null) ...[
                const SizedBox(height: 12),
                Text(c.error!,
                    style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: c.refreshing
                      ? null
                      : () => c.importSubscription(_text.text),
                  child: c.refreshing
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Добавить подписку'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
