import 'package:flutter/material.dart';

import '../app_state.dart';

/// Выбор приложений для раздельного туннелирования.
class AppsScreen extends StatefulWidget {
  const AppsScreen({super.key, required this.controller});
  final AppController controller;

  @override
  State<AppsScreen> createState() => _AppsScreenState();
}

class _AppsScreenState extends State<AppsScreen> {
  List<({String name, String package})>? _apps;
  String _query = '';
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.controller.installedApps().then((v) {
      if (mounted) setState(() => _apps = v);
    }).catchError((Object e) {
      if (mounted) setState(() => _error = 'Не удалось получить список приложений.');
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final mode = c.settings.splitMode;
    final title = mode == 'only' ? 'Через VPN только эти' : 'Эти приложения мимо VPN';
    final list = (_apps ?? const [])
        .where((a) => a.name.toLowerCase().contains(_query.toLowerCase()))
        .toList();

    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: Text(title)),
        body: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Поиск приложения',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          Expanded(
            child: _error != null
                ? Center(child: Text(_error!))
                : _apps == null
                    ? const Center(child: CircularProgressIndicator())
                    : ListView.builder(
                        itemCount: list.length,
                        itemBuilder: (context, i) {
                          final a = list[i];
                          final on = c.settings.splitApps.contains(a.package);
                          return CheckboxListTile(
                            value: on,
                            title: Text(a.name),
                            subtitle: Text(a.package,
                                style: const TextStyle(fontSize: 11)),
                            onChanged: (v) => c.updateSettings((s) {
                              if (v == true) {
                                s.splitApps.add(a.package);
                              } else {
                                s.splitApps.remove(a.package);
                              }
                            }),
                          );
                        },
                      ),
          ),
        ]),
      ),
    );
  }
}
