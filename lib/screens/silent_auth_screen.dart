import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'live_transcript_screen.dart';

class SilentAuthScreen extends StatefulWidget {
  final String originalUrl;
  final String resolvedUrl;

  const SilentAuthScreen({
    super.key,
    required this.originalUrl,
    required this.resolvedUrl,
  });

  @override
  State<SilentAuthScreen> createState() => _SilentAuthScreenState();
}

class _SilentAuthScreenState extends State<SilentAuthScreen> {
  InAppWebViewController? _controller;
  bool _isLoading = true;
  bool _isAuthenticated = false;
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  @override
  void initState() {
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Loading…'),
        automaticallyImplyLeading: false,
      ),
      body: InAppWebView(
        initialUrlRequest: URLRequest(url: WebUri(widget.originalUrl)),
        onWebViewCreated: (controller) {
          _controller = controller;
        },
        onLoadStop: (controller, url) async {
          setState(() => _isLoading = false);
          await _checkCookies(controller);
        },
        onLoadError: (controller, url, code, message) {
          if (kDebugMode) {
            print('WebView error: $code - $message');
          }
          setState(() => _isLoading = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to load the page. Please try again.')),
          );
        },
      ),
    );
  }

  Future<void> _checkCookies(InAppWebViewController controller) async {
    if (_isAuthenticated) return;

    try {
      final cookies = await controller.evaluateJavascript(
        source: 'document.cookie',
      );
      if (cookies != null &&
          cookies.isNotEmpty &&
          cookies.toString().contains('_forward_auth_csrf')) {
        await _storage.write(key: 'cookies', value: cookies.toString());
        if (mounted && !_isAuthenticated) {
          setState(() => _isAuthenticated = true);
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (_) => LiveTranscriptScreen(
                resolvedUrl: widget.resolvedUrl,
                originalUrl: widget.originalUrl,
              ),
            ),
          );
        }
      } else {
        // Not authenticated – check again after 3 seconds
        Future.delayed(const Duration(seconds: 3), () {
          if (mounted && !_isAuthenticated) {
            _checkCookies(controller);
          }
        });
      }
    } catch (e) {
      if (kDebugMode) {
        print('Error extracting cookies: $e');
      }
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted && !_isAuthenticated) {
          _checkCookies(controller);
        }
      });
    }
  }
}