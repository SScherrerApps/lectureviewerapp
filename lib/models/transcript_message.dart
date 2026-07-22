import 'dart:typed_data';

class TranscriptMessage {
  final String transcript;
  final Map<String, String> translations;
  final DateTime timestamp;
  final String language;
  final bool isUnstable;
  final Uint8List? audioData;   // used on non-web (downloaded bytes)
  final String? audioUrl;       // used on web (direct URL)

  TranscriptMessage({
    required this.transcript,
    required this.translations,
    required this.timestamp,
    required this.language,
    this.isUnstable = false,
    this.audioData,
    this.audioUrl,
  });
}