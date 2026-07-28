import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:vactonline/firebase_options.dart';

import 'screens/splash_screen.dart';
import 'screens/login_screen.dart';
import 'screens/register_screen.dart';
import 'screens/main_shell.dart';
import 'screens/ringing_screen.dart';
import 'screens/incoming_call_screen.dart';
import 'screens/call_screen.dart';

// NOTE: Firebase.initializeApp() is called after you run:
//   flutterfire configure
// which generates lib/firebase_options.dart.
// Until then, Firebase Auth + Cloud Functions calls will fail gracefully.

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ─── Uncomment after running `flutterfire configure` ─────────────────────
  await Firebase.initializeApp(options:
   DefaultFirebaseOptions.currentPlatform);
  // ─────────────────────────────────────────────────────────────────────────

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VactOnline Video Call',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.dark(
          primary: const Color(0xFF00E5FF), // Electric Cyan
          secondary: const Color(0xFF8A2BE2), // Neon Purple
          surface: const Color(0xFF141421), // Slightly lighter glass base
        ),
        scaffoldBackgroundColor: const Color(0xFF0B0B13), // Deep rich dark
        textTheme: GoogleFonts.outfitTextTheme(
          Theme.of(context).textTheme.apply(
                bodyColor: Colors.white,
                displayColor: Colors.white,
              ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white.withValues(alpha: 0.05),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: Color(0xFF00E5FF), width: 2),
          ),
          labelStyle: const TextStyle(color: Colors.white54),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF8A2BE2),
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 18),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            elevation: 8,
            shadowColor: const Color(0xFF8A2BE2).withValues(alpha: 0.5),
          ),
        ),
      ),
      initialRoute: '/',
      routes: {
        '/': (context) => const SplashScreen(),
        '/login': (context) => const LoginScreen(),
        '/register': (context) => const RegisterScreen(),
        '/home': (context) => const MainShell(),
        '/ringing': (context) => const RingingScreen(),
        '/incoming': (context) => const IncomingCallScreen(),
        '/call': (context) => const CallScreen(),
      },
    );
  }
}
