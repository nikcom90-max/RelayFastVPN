import 'dart:async';
import 'dart:io' show Platform;

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';

import 'app_state.dart';
import 'screens/blocked_screen.dart';
import 'screens/import_screen.dart';
import 'screens/root_screen.dart';

Color _parseColor(String? hex, Color fallback) {
  if (hex == null) return fallback;
  final h = hex.replaceFirst('#', '');
  if (h.length != 6) return fallback;
  final v = int.tryParse(h, radix: 16);
  return v == null ? fallback : Color(0xFF000000 | v);
}

/// Фирменная тёмная тема: глубокий navy + неон (циан / фиолет / оранж).
const brandPurple = Color(0xFFA66BFF);
const brandOrange = Color(0xFFFF9A3C);
const brandBg = Color(0xFF070B1F);

ThemeData brandTheme(Color accent) {
  final scheme = ColorScheme.fromSeed(
    seedColor: accent,
    brightness: Brightness.dark,
  ).copyWith(
    primary: accent,
    secondary: brandPurple,
    tertiary: brandOrange,
    surface: brandBg,
    surfaceContainer: const Color(0xFF0E1433),
    surfaceContainerHighest: const Color(0xFF1A2147),
    secondaryContainer: const Color(0xFF1E2655),
    onSecondaryContainer: Colors.white,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: brandBg,
    appBarTheme: const AppBarTheme(
        backgroundColor: brandBg, surfaceTintColor: Colors.transparent),
    cardTheme: CardThemeData(
      color: const Color(0xFF111735),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: accent.withOpacity(.18)),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        foregroundColor: brandBg,
      ),
    ),
  );
}

ThemeData brandLightTheme(Color accent) {
  final scheme = ColorScheme.fromSeed(seedColor: accent).copyWith(
    primary: Color.alphaBlend(Colors.black.withOpacity(.25), accent),
    secondary: brandPurple,
    surface: const Color(0xFFF5F7FF),
    surfaceContainer: Colors.white,
    surfaceContainerHighest: const Color(0xFFE6EAFB),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface, surfaceTintColor: Colors.transparent),
    cardTheme: CardThemeData(
      color: Colors.white,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: scheme.primary.withOpacity(.18)),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
  );
}

class RelayFastApp extends StatefulWidget {
  const RelayFastApp({super.key, required this.controller});
  final AppController controller;

  @override
  State<RelayFastApp> createState() => _RelayFastAppState();
}

class _RelayFastAppState extends State<RelayFastApp> {
  StreamSubscription<Uri>? _links;

  @override
  void initState() {
    super.initState();
    if (!Platform.isWindows) {
      final links = AppLinks();
      // relayfast://import?url=<https-ссылка подписки> — кнопка из бота/страницы.
      _links = links.uriLinkStream.listen(_handleLink);
      links.getInitialLink().then((u) {
        if (u != null) _handleLink(u);
      });
    }
  }

  void _handleLink(Uri uri) {
    if (uri.scheme != 'relayfast') return;
    final url = uri.queryParameters['url'];
    if (url != null && url.isNotEmpty) {
      widget.controller.importSubscription(url);
    }
  }

  @override
  void dispose() {
    _links?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final accent = _parseColor(c.remote.accentHex, const Color(0xFF35C8FF));
        final Widget home;
        if (c.blockReason != BlockReason.none) {
          home = BlockedScreen(controller: c);
        } else if (!c.hasSubscription) {
          home = ImportScreen(controller: c);
        } else {
          home = RootScreen(controller: c);
        }
        return MaterialApp(
          title: c.brandName,
          debugShowCheckedModeBanner: false,
          themeMode: switch (c.settings.theme) {
            'light' => ThemeMode.light,
            'system' => ThemeMode.system,
            _ => ThemeMode.dark,
          },
          theme: brandLightTheme(accent),
          darkTheme: brandTheme(accent),
          home: home,
        );
      },
    );
  }
}
