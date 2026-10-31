import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/app_state.dart';
import 'src/windows/tray_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = AppController();
  await controller.init();
  await TrayService.start(controller); // значок в трее (только Windows)
  runApp(RelayFastApp(controller: controller));
}
