// ignore_for_file: use_build_context_synchronously

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, kDebugMode;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

class QRScannerScreen extends StatefulWidget {
  const QRScannerScreen({super.key});

  @override
  State<QRScannerScreen> createState() => _QRScannerScreenState();
}

class _QRScannerScreenState extends State<QRScannerScreen> {
  bool get _cameraSupported {
    if (kIsWeb) return true;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
        return true;
      case TargetPlatform.windows:
      case TargetPlatform.macOS:
      case TargetPlatform.linux:
        return false;
      default:
        return false;
    }
  }

  late final MobileScannerController? scannerController =
      _cameraSupported ? MobileScannerController() : null;

  bool _isProcessing = false;

  @override
  void dispose() {
    scannerController?.dispose();
    super.dispose();
  }

  // Helper to recursively search JSON for a WebSocket URL string
  String? _findWebSocketUrlInJson(dynamic json) {
    if (json == null) return null;
    if (json is String) {
      if (json.startsWith('ws://') || json.startsWith('wss://')) {
        return json;
      }
      return null;
    }
    if (json is Map) {
      for (var value in json.values) {
        final result = _findWebSocketUrlInJson(value);
        if (result != null) return result;
      }
    }
    if (json is List) {
      for (var item in json) {
        final result = _findWebSocketUrlInJson(item);
        if (result != null) return result;
      }
    }
    return null;
  }

  // ✅ FIXED: ONLY returns ws:// or wss:// URLs
  Future<String> _resolveUrl(String input) async {
    input = input.trim();

    // 1. Already a WebSocket URL?
    if (input.startsWith('ws://') || input.startsWith('wss://')) {
      return input;
    }

    // 2. Must be an HTTP(S) URL to fetch
    if (!input.startsWith('http://') && !input.startsWith('https://')) {
      throw Exception(
          'Invalid URL format. Please enter a ws://, wss://, http://, or https:// URL.');
    }

    final response = await http.get(Uri.parse(input));
    if (response.statusCode != 200) {
      throw Exception('Server returned HTTP ${response.statusCode}');
    }

    String body = response.body.trim();

    // 🔍 DEBUG: print the raw response to the console (this will appear in the terminal)
    if (kDebugMode) {
      print('===== RAW RESPONSE =====');
    }
    if (kDebugMode) {
      print(body);
    }
    if (kDebugMode) {
      print('========================');
    }

    // 3. Try to parse as JSON
    try {
      final json = jsonDecode(body);
      String? found = _findWebSocketUrlInJson(json);
      if (found != null) {
        if (found.startsWith('ws://') || found.startsWith('wss://')) {
          return found;
        } else {
          throw Exception('Found a URL in JSON but it is not a WebSocket endpoint: $found');
        }
      }
    } catch (_) {
      // Not JSON, continue
    }

    // 4. If the whole body is a WebSocket URL, use it
    if (body.startsWith('ws://') || body.startsWith('wss://')) {
      return body;
    }

    // 5. Use regex to find ws:// or wss:// URLs ONLY
    final regex = RegExp(r'(wss?://[^\s"]+)');
    final match = regex.firstMatch(body);
    if (match != null) {
      String url = match.group(0)!;
      if (url.startsWith('ws://') || url.startsWith('wss://')) {
        return url;
      }
      // If it's not a WebSocket URL, ignore it.
    }

    // 6. Nothing worked – throw with the response body for debugging
    throw Exception(
      'Could not find a WebSocket URL (wss:// or ws://) in the response.\n'
      'Response body (first 300 chars): ${body.substring(0, body.length > 300 ? 300 : body.length)}',
    );
  }

  // Save URL to history
  Future<void> _addToHistory(String url) async {
    final prefs = await SharedPreferences.getInstance();
    List<String> history = prefs.getStringList('session_history') ?? [];
    history.remove(url);
    history.insert(0, url);
    if (history.length > 20) history = history.sublist(0, 20);
    await prefs.setStringList('session_history', history);
  }

  Future<void> _proceedWithUrl(String rawInput) async {
    if (rawInput.trim().isEmpty) return;

    setState(() => _isProcessing = true);

    if (scannerController != null) {
      await scannerController!.stop();
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    String websocketUrl = '';

    try {
      websocketUrl = await _resolveUrl(rawInput);

      // Save to history
      await _addToHistory(websocketUrl);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('session_url', websocketUrl);

      if (mounted) {
        Navigator.pop(context);
        Navigator.pushReplacementNamed(
          context,
          '/live',
          arguments: websocketUrl,
        );
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.red,
          ),
        );
        await scannerController?.start();
        setState(() => _isProcessing = false);
      }
    }
  }

  Widget _buildManualEntryScreen() {
    final TextEditingController textController = TextEditingController();

    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.link, size: 80, color: Colors.blue),
          const SizedBox(height: 24),
          const Text(
            'Enter the WebSocket URL manually',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          const Text(
            'Camera is not available on this platform.\nPaste or type the URL below.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: Colors.grey),
          ),
          const SizedBox(height: 32),
          TextField(
            controller: textController,
            decoration: const InputDecoration(
              hintText: 'wss://example.com/ws  or  https://.../shorten/...',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.link),
            ),
            autofocus: true,
            keyboardType: TextInputType.url,
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: () {
              final url = textController.text.trim();
              if (url.isNotEmpty) {
                _proceedWithUrl(url);
              }
            },
            icon: const Icon(Icons.arrow_forward),
            label: const Text('Connect'),
            style: ElevatedButton.styleFrom(
              minimumSize: const Size(double.infinity, 50),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScannerUI() {
    return Stack(
      children: [
        MobileScanner(
          controller: scannerController!,
          onDetect: _onScanComplete,
        ),
        const Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Point camera at QR code or tap ✏️ to enter URL manually',
              style: TextStyle(
                color: Colors.white,
                backgroundColor: Colors.black54,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _onScanComplete(BarcodeCapture capture) async {
    if (_isProcessing) return;
    final String? rawValue = capture.barcodes.first.rawValue;
    if (rawValue == null) return;
    await _proceedWithUrl(rawValue);
  }

  void _showManualEntryDialog() {
    final TextEditingController textController = TextEditingController();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Enter WebSocket or HTTPS URL'),
        content: TextField(
          controller: textController,
          decoration: const InputDecoration(
            hintText: 'wss://example.com/ws  or  https://.../shorten/...',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
          keyboardType: TextInputType.url,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final url = textController.text.trim();
              if (url.isNotEmpty) {
                Navigator.pop(context);
                _proceedWithUrl(url);
              }
            },
            child: const Text('Connect'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool useCamera = _cameraSupported;

    return Scaffold(
      appBar: AppBar(
        title: Text(useCamera ? 'Scan QR Code' : 'Enter URL'),
      ),
      body: useCamera
          ? _buildScannerUI()
          : _buildManualEntryScreen(),
      floatingActionButton: useCamera
          ? FloatingActionButton.extended(
              onPressed: _showManualEntryDialog,
              icon: const Icon(Icons.edit),
              label: const Text('Enter URL manually'),
            )
          : null,
    );
  }
}