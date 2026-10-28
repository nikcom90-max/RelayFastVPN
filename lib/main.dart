import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/app_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = AppController();
  await controller.init();
  runApp(RelayFastApp(controller: controller));
}
