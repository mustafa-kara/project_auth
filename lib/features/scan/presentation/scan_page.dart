/// QR tarama ekranı (placeholder).
///
/// Faz 1: `mobile_scanner` ile gerçek kamera taraması + otpauth:// tespiti
/// burada uygulanacak. Şimdilik iskelet — kamera izni akışı eklenince doldurulur.
library;

import 'package:flutter/material.dart';

class ScanPage extends StatelessWidget {
  const ScanPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('QR Tara')),
      body: const Center(
        child: Text('QR tarama Faz 1 ilerleyen adımda eklenecek'),
      ),
    );
  }
}
