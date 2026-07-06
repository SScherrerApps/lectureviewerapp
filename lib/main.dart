import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'screens/qr_scanner_screen.dart';
import 'screens/live_transcript_screen.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:io' show Platform; // Needed to check the platform

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

    // ----- Web & Windows Initialization (Using Dart options) -----
  if (kIsWeb || Platform.isWindows) {
    // For Firebase JS SDK v7.20.0 and later, measurementId is optional
    const firebaseOptions = FirebaseOptions(
       apiKey: "AIzaSyDzSrmUy6SB2mSj0IZ3lOIJZ4de5fmps4w",
       authDomain: "lectureviewerapp.firebaseapp.com",
       projectId: "lectureviewerapp",
       storageBucket: "lectureviewerapp.firebasestorage.app",
       messagingSenderId: "844850086526",
       appId: "1:844850086526:web:916ab321abf65eaa818e2f",
       measurementId: "G-EJM5LW14VS"
    );
    await Firebase.initializeApp(options: firebaseOptions);
  } 
  // ----- Android & iOS Initialization (Using config files) -----
  else {
    // This will automatically read:
    // - android/app/google-services.json
    // - ios/Runner/GoogleService-Info.plist
    await Firebase.initializeApp();
  }

  await Firebase.initializeApp();
  final prefs = await SharedPreferences.getInstance();
  final savedUrl = prefs.getString('session_url');
  runApp(MyApp(initialUrl: savedUrl));
}

class MyApp extends StatelessWidget {
  final String? initialUrl;
  const MyApp({super.key, this.initialUrl});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ASR Live Translator',
      theme: ThemeData(useMaterial3: true),
      initialRoute: initialUrl == null ? '/scan' : '/live',
      routes: {
        '/scan': (context) => const QRScannerScreen(),
        '/live': (context) {
          final args = ModalRoute.of(context)!.settings.arguments as String?;
          final url = args ?? initialUrl;
          if (url == null) return const QRScannerScreen();
          return LiveTranscriptScreen(initialUrl: url);
        },
      },
    );
  }
}