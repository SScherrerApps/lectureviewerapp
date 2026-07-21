import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:webview_windows/webview_windows.dart';
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
  WebviewController? _controller;
  bool _isLoading = true;
  bool _isAuthenticated = false;
  String? _errorMessage;
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  @override
  void initState() {
    super.initState();
    _initWebView();
  }

  // 👇 Cancel authentication and go back to session list
  void _cancelAuth() {
    _controller?.dispose();
    if (mounted) {
      // Navigate back to the session list (root)
      Navigator.pushReplacementNamed(context, '/');
    }
  }

  Future<void> _initWebView() async {
    try {
      if (kDebugMode) print('Initializing WebView...');
      final controller = WebviewController();
      await controller.initialize();
      if (kDebugMode) print('WebView initialized successfully.');

      await controller.loadUrl(widget.originalUrl);
      if (kDebugMode) print('Loaded URL: ${widget.originalUrl}');

      if (mounted) {
        setState(() {
          _controller = controller;
          _isLoading = false;
        });
        // Start checking cookies periodically
        _checkCookies(controller);
      }
    } catch (e) {
      if (kDebugMode) print('WebView init error: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Failed to initialize WebView: ${e.toString()}';
        });
      }
    }
  }

  Future<void> _checkCookies(WebviewController controller) async {
    if (_isAuthenticated || !mounted) return;

    try {
      final cookies = await controller.executeScript('document.cookie');
      if (kDebugMode) print('Cookies: $cookies');

      if (cookies != null && cookies.isNotEmpty && cookies.contains('_forward_auth_csrf')) {
        await _storage.write(key: 'cookies', value: cookies);
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
        // Check again after 3 seconds
        Future.delayed(const Duration(seconds: 3), () {
          if (mounted && !_isAuthenticated) {
            _checkCookies(controller);
          }
        });
      }
    } catch (e) {
      if (kDebugMode) print('Error extracting cookies: $e');
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted && !_isAuthenticated) {
          _checkCookies(controller);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_errorMessage != null) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Error'),
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: _cancelAuth,
            tooltip: 'Cancel',
          ),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline, size: 64, color: Colors.red),
                const SizedBox(height: 16),
                Text(_errorMessage!,
                    style: const TextStyle(fontSize: 16),
                    textAlign: TextAlign.center),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: () {
                    setState(() {
                      _errorMessage = null;
                      _isLoading = true;
                    });
                    _initWebView();
                  },
                  child: const Text('Retry'),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: _cancelAuth,
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Authenticating…'),
        // 👇 Add a cancel button on the left
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: _cancelAuth,
          tooltip: 'Cancel authentication',
        ),
        // Keep the back arrow optional – but we have our own close
        automaticallyImplyLeading: false,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _controller != null
              ? Webview(_controller!)
              : const Center(child: Text('Failed to load WebView')),
    );
  }
}