import 'package:flutter/material.dart';
import 'package:text_masking_scanner/text_masking_scanner.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  @override
  void initState() {
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: TextMaskingScanner(
          onBarcodes: (barcodes) {},
        ),
      ),
    );
  }
}