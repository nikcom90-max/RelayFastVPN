import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Сканер QR-кода со ссылкой подписки. Закрывается и возвращает текст кода.
class QrScreen extends StatefulWidget {
  const QrScreen({super.key});

  @override
  State<QrScreen> createState() => _QrScreenState();
}

class _QrScreenState extends State<QrScreen> {
  bool _done = false;

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final b in capture.barcodes) {
      final v = b.rawValue;
      if (v != null && v.trim().isNotEmpty) {
        _done = true;
        Navigator.of(context).pop(v.trim());
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Сканировать QR-код')),
      body: Stack(children: [
        MobileScanner(
          onDetect: _onDetect,
          errorBuilder: (context, error, child) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                  error.errorCode == MobileScannerErrorCode.permissionDenied
                      ? 'Нет доступа к камере. Разрешите камеру в настройках телефона '
                          'или вставьте ссылку вручную.'
                      : 'Не удалось запустить камеру (${error.errorCode.name}). '
                          '${error.errorDetails?.message ?? ''}\n'
                          'Вставьте ссылку вручную.',
                  textAlign: TextAlign.center),
            ),
          ),
        ),
        const Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text('Наведите камеру на QR-код подписки',
                style: TextStyle(color: Colors.white)),
          ),
        ),
      ]),
    );
  }
}
