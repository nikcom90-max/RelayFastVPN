import 'package:flutter/material.dart';

import '../app_state.dart';
import 'home_screen.dart';
import 'pay_screen.dart';

/// Каркас с нижним меню: «Главная» и «Оплата».
class RootScreen extends StatefulWidget {
  const RootScreen({super.key, required this.controller});
  final AppController controller;

  @override
  State<RootScreen> createState() => _RootScreenState();
}

class _RootScreenState extends State<RootScreen> {
  // Вкладку «Оплата» создаём при первом открытии, чтобы не грузить тарифы зря.
  bool _payOpened = false;

  @override
  void initState() {
    super.initState();
    _payOpened = widget.controller.tab.value == 1;
    widget.controller.tab.addListener(_onTab);
  }

  @override
  void dispose() {
    widget.controller.tab.removeListener(_onTab);
    super.dispose();
  }

  void _onTab() {
    if (widget.controller.tab.value == 1) _payOpened = true;
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final index = c.tab.value;
    return PopScope(
      // «Назад» на вкладке оплаты возвращает на главную, а не закрывает приложение
      canPop: index == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) c.tab.value = 0;
      },
      child: Scaffold(
      body: IndexedStack(
        index: index,
        children: [
          HomeScreen(controller: c),
          _payOpened ? PayScreen(controller: c) : const SizedBox.shrink(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (i) => c.tab.value = i,
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.shield_outlined),
              selectedIcon: Icon(Icons.shield),
              label: 'Главная'),
          NavigationDestination(
              icon: Icon(Icons.credit_card_outlined),
              selectedIcon: Icon(Icons.credit_card),
              label: 'Оплата'),
        ],
      ),
    ));
  }
}
