import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import '../models/transcript_message.dart';

class LiveTranscriptScreen extends StatefulWidget {
  final String initialUrl;
  const LiveTranscriptScreen({super.key, required this.initialUrl});

  @override
  State<LiveTranscriptScreen> createState() => _LiveTranscriptScreenState();
}

class _LiveTranscriptScreenState extends State<LiveTranscriptScreen> {
  String? _selectedLanguage; // null = show all
  final Set<String> _availableLanguages = {};
  final List<TranscriptMessage> _messages = [];
  bool _defaultFilterSet = false; // set once when first message arrives

  WebSocketChannel? _channel;
  StreamSubscription? _sseSubscription;
  bool _isConnected = false;
  String? _errorMessage;
  bool _isConnecting = false;

  // TTS
  final FlutterTts _flutterTts = FlutterTts();
  bool _ttsEnabled = true;

  // Firestore
  CollectionReference? _transcriptsRef;
  String _sessionId = '';

  bool get _isDesktop {
    if (kIsWeb) return false;
    switch (defaultTargetPlatform) {
      case TargetPlatform.windows:
      case TargetPlatform.macOS:
      case TargetPlatform.linux:
        return true;
      default:
        return false;
    }
  }

  @override
  void initState() {
    super.initState();
    _initTts();
    _initFirebaseAndSession();
  }

  Future<void> _initTts() async {
    await _flutterTts.setLanguage("en-US");
    await _flutterTts.setSpeechRate(0.5);
    await _flutterTts.setPitch(1.0);
  }

  Future<void> _initFirebaseAndSession() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        await FirebaseAuth.instance.signInAnonymously();
      }
      final currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser != null) {
        final prefs = await SharedPreferences.getInstance();
        _sessionId = prefs.getString('session_id_${widget.initialUrl}') ??
            DateTime.now().millisecondsSinceEpoch.toString();
        await prefs.setString('session_id_${widget.initialUrl}', _sessionId);
        _transcriptsRef = FirebaseFirestore.instance
            .collection('users')
            .doc(currentUser.uid)
            .collection('sessions')
            .doc(_sessionId)
            .collection('transcripts');
      }
    } catch (e) {
      if (_isDesktop) {
        debugPrint('⚠️ Firebase not configured on desktop. Continuing without it.');
      } else {
        debugPrint('Firebase error: $e');
        setState(() => _errorMessage = 'Firebase error: $e (will still try to connect)');
      }
      _sessionId = 'temp_${DateTime.now().millisecondsSinceEpoch}';
    }
    _connect(widget.initialUrl);
  }

  // ─── Connection dispatcher ───────────────────────────────
  void _connect(String url) {
    setState(() {
      _errorMessage = null;
      _isConnected = false;
      _isConnecting = true;
      _messages.clear();
      _availableLanguages.clear();
      _defaultFilterSet = false; // reset on reconnect
      _selectedLanguage = null;
    });

    if (url.startsWith('http://') || url.startsWith('https://')) {
      _connectSSE(url);
    } else {
      _connectWebSocket(url);
    }
  }

  // ─── Manual SSE client ───────────────────────────────────
  void _connectSSE(String url) {
    debugPrint('🔗 Connecting to SSE: $url');

    final headers = {
      'Accept': 'text/event-stream',
      'Cache-Control': 'no-cache',
      'Connection': 'keep-alive',
    };

    http.Client().send(http.Request('GET', Uri.parse(url))
      ..headers.addAll(headers)
    ).then((response) {
      if (response.statusCode != 200) {
        throw Exception('Server returned HTTP ${response.statusCode}');
      }
      final stream = response.stream.transform(utf8.decoder);

      String buffer = '';
      StreamSubscription<String> subscription;
      subscription = stream.listen((String chunk) {
        buffer += chunk;
        final events = buffer.split('\n\n');
        if (events.length > 1) {
          buffer = events.removeLast();
          for (final eventBlock in events) {
            _parseSSEEvent(eventBlock);
          }
        }
      }, onError: (error) {
        debugPrint('❌ SSE stream error: $error');
        setState(() {
          _errorMessage = 'SSE error: $error';
          _isConnected = false;
          _isConnecting = false;
        });
      }, onDone: () {
        debugPrint('🔌 SSE disconnected');
        setState(() {
          _isConnected = false;
          _isConnecting = false;
        });
      });
      _sseSubscription = subscription;

      setState(() {
        _isConnected = true;
        _isConnecting = false;
      });
    }).catchError((error) {
      debugPrint('❌ Failed to connect SSE: $error');
      setState(() {
        _errorMessage = 'Failed to connect: $error';
        _isConnected = false;
        _isConnecting = false;
      });
    });
  }

  void _parseSSEEvent(String eventBlock) {
    debugPrint('📦 Full SSE event block:\n$eventBlock');
    final lines = eventBlock.split('\n');
    StringBuffer dataBuffer = StringBuffer();

    for (final line in lines) {
      if (line.startsWith('data:')) {
        dataBuffer.writeln(line.substring(5).trim());
      }
    }

    final data = dataBuffer.toString().trim();
    if (data.isEmpty) return;

    try {
      final json = jsonDecode(data);
      _handleMessage(json);
    } catch (e) {
      debugPrint('⚠️ Failed to parse SSE data: $e');
    }
  }

  // ─── WebSocket connection (fallback) ────────────────────
  void _connectWebSocket(String url) {
    debugPrint('🔗 Connecting to WebSocket: $url');

    try {
      _channel = WebSocketChannel.connect(Uri.parse(url));
      _channel!.stream.listen(
        (data) async {
          try {
            final Map<String, dynamic> json =
                data is String ? jsonDecode(data) : data as Map<String, dynamic>;
            await _handleMessage(json);
          } catch (e) {
            debugPrint('⚠️ WebSocket parse error: $e');
          }
        },
        onError: (error) {
          debugPrint('❌ WebSocket error: $error');
          setState(() {
            _errorMessage = 'WebSocket error: $error';
            _isConnected = false;
            _isConnecting = false;
          });
        },
        onDone: () {
          debugPrint('🔌 WebSocket disconnected');
          setState(() {
            _isConnected = false;
            _isConnecting = false;
          });
        },
      );
    } catch (e) {
      debugPrint('❌ Failed to connect WebSocket: $e');
      setState(() {
        _errorMessage = 'Failed to connect: $e';
        _isConnected = false;
        _isConnecting = false;
      });
    }
  }

  // ─── Language extraction from sender ────────────────────
  String _extractLanguageFromSender(String sender) {
    // ASR sender → Transcript
    if (sender.startsWith('asr')) {
      return 'Transcript';
    }

    // Try to extract language code from sender like "textstructurer:0_en"
    final parts = sender.split('_');
    if (parts.length > 1) {
      final code = parts.last;
      // Map common codes to display names
      switch (code) {
        case 'en': return 'English';
        case 'de': return 'German';
        case 'fr': return 'French';
        case 'zh': return 'Chinese';
        case 'it': return 'Italian';
        case 'ja': return 'Japanese';
        case 'fa': return 'Persian';
        case 'ru': return 'Russian';
        case 'es': return 'Spanish';
        case 'vi': return 'Vietnamese';
        default: return code.toUpperCase();
      }
    }

    // Fallback: if sender starts with "mt:" we could map index to language,
    // but it's simpler to return 'unknown'.
    return 'unknown';
  }

  // ─── Message handler ─────────────────────────────────────
  Future<void> _handleMessage(Map<String, dynamic> json) async {
    debugPrint('📩 JSON keys: ${json.keys}');
    debugPrint('🔍 sender: "${json['sender']}"');

    String transcriptText = (json['seq'] ?? '').toString().trim();
    if (transcriptText.isEmpty) {
      debugPrint('⏭️ Skipping message with empty seq');
      return;
    }

    // Extract language from sender
    final sender = json['sender'] ?? '';
    final language = _extractLanguageFromSender(sender);
    _availableLanguages.add(language);

    // Set default filter to the first language (usually 'Transcript')
    if (!_defaultFilterSet) {
      _selectedLanguage = language;
      _defaultFilterSet = true;
    }

    final message = TranscriptMessage(
      transcript: transcriptText,
      translations: {},
      timestamp: DateTime.now(),
      language: language,
    );

    _messages.add(message);

    if (_transcriptsRef != null) {
      try {
        await _transcriptsRef!.add({
          'transcript': message.transcript,
          'translations': message.translations,
          'timestamp': Timestamp.fromDate(message.timestamp),
          'language': message.language,
        });
      } catch (e) {
        debugPrint('⚠️ Could not save to Firestore: $e');
      }
    }

    setState(() {
      _isConnected = true;
      _isConnecting = false;
    });

    // TTS – speak only if filter matches (or all)
    bool shouldSpeak = _ttsEnabled &&
        message.transcript.isNotEmpty &&
        !message.transcript.startsWith('{');
    if (shouldSpeak) {
      if (_selectedLanguage == null ||
          message.language.toLowerCase() == _selectedLanguage!.toLowerCase()) {
        await _flutterTts.speak(message.transcript);
      }
    }
  }

  // ─── Helpers ────────────────────────────────────────────
  void _reconnect() {
    _channel?.sink.close();
    _sseSubscription?.cancel();
    _sseSubscription = null;
    _connect(widget.initialUrl);
  }

  Future<void> _toggleTts() async {
    setState(() => _ttsEnabled = !_ttsEnabled);
    if (!_ttsEnabled) {
      await _flutterTts.stop();
    }
  }

  Future<void> _scanNewQR() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('session_url');
    await prefs.remove('session_id_${widget.initialUrl}');
    _channel?.sink.close();
    _sseSubscription?.cancel();
    _sseSubscription = null;
    await _flutterTts.stop();
    if (mounted) {
      Navigator.pushReplacementNamed(context, '/scan');
    }
  }

  @override
  void dispose() {
    _channel?.sink.close();
    _sseSubscription?.cancel();
    _sseSubscription = null;
    _flutterTts.stop();
    super.dispose();
  }

  // ─── Build ───────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    // Filter messages
    List<TranscriptMessage> filteredMessages;
    if (_selectedLanguage == null) {
      filteredMessages = List.from(_messages);
    } else {
      filteredMessages = _messages
          .where((msg) =>
              msg.language.toLowerCase() == _selectedLanguage!.toLowerCase())
          .toList();
    }
    filteredMessages.sort((a, b) => a.timestamp.compareTo(b.timestamp));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Live Transcript'),
        actions: [
          IconButton(
            icon: Icon(_ttsEnabled ? Icons.volume_up : Icons.volume_off),
            onPressed: _toggleTts,
            tooltip: 'Toggle TTS',
          ),
          if (_availableLanguages.isNotEmpty)
            DropdownButton<String>(
              value: _selectedLanguage,
              hint: const Text('All'),
              items: [
                const DropdownMenuItem<String>(
                  value: null,
                  child: Text('All (transcript)'),
                ),
                ..._availableLanguages.map((lang) {
                  return DropdownMenuItem<String>(
                    value: lang,
                    child: Text(lang == 'unknown' ? 'Unknown' : lang),
                  );
                }),
              ],
              onChanged: (newLang) {
                setState(() {
                  _selectedLanguage = newLang;
                });
              },
            ),
          IconButton(
            icon: const Icon(Icons.qr_code_scanner),
            onPressed: _scanNewQR,
            tooltip: 'Scan new QR',
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            color: _isConnected ? Colors.green.shade100 : Colors.red.shade100,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  _isConnected ? Icons.wifi : (_isConnecting ? Icons.wifi_lock : Icons.wifi_off),
                  color: _isConnected ? Colors.green : (_isConnecting ? Colors.orange : Colors.red),
                ),
                const SizedBox(width: 8),
                Text(_isConnected ? 'Live connection' : (_isConnecting ? 'Connecting...' : 'Disconnected')),
                if (_selectedLanguage != null) ...[
                  const SizedBox(width: 12),
                  Chip(
                    label: Text('Filter: ${_selectedLanguage == 'unknown' ? 'Unknown' : _selectedLanguage}'),
                    backgroundColor: Colors.blue.shade100,
                    deleteIcon: const Icon(Icons.close, size: 16),
                    onDeleted: () {
                      setState(() {
                        _selectedLanguage = null;
                      });
                    },
                  ),
                ],
                if (_errorMessage != null) ...[
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      _errorMessage!,
                      style: const TextStyle(color: Colors.red),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
                if (!_isConnected && !_isConnecting) ...[
                  const SizedBox(width: 16),
                  TextButton(
                    onPressed: _reconnect,
                    child: const Text('Retry'),
                  ),
                ],
              ],
            ),
          ),
          Expanded(
            child: filteredMessages.isEmpty
                ? Center(
                    child: Text(
                      _messages.isEmpty
                          ? 'Waiting for transcript...'
                          : 'No messages in ${_selectedLanguage == 'unknown' ? 'Unknown' : _selectedLanguage}',
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: filteredMessages.length,
                    itemBuilder: (context, index) {
                      final msg = filteredMessages[index];
                      return Card(
                        elevation: 2,
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      msg.transcript,
                                      style: const TextStyle(fontSize: 18),
                                    ),
                                  ),
                                  Text(
                                    '${msg.timestamp.hour.toString().padLeft(2, '0')}:${msg.timestamp.minute.toString().padLeft(2, '0')}:${msg.timestamp.second.toString().padLeft(2, '0')}',
                                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Language: ${msg.language == 'unknown' ? 'Unknown' : msg.language}',
                                style: const TextStyle(fontSize: 12, color: Colors.blueGrey),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}