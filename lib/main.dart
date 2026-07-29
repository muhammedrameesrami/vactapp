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

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:vact_sdk/vact_sdk.dart';
import 'services/vact_service.dart';
import 'services/call_log_service.dart';
import 'package:firebase_auth/firebase_auth.dart';

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  
  if (message.data.containsKey('callId')) {
    final callId = message.data['callId'];
    final fromUserId = message.data['from'] ?? message.data['fromUserId'];
    String callerName = message.data['callerName'] ?? fromUserId ?? 'Unknown';
    final callType = message.data['callType'] ?? 'video';

    if (callerName == fromUserId) {
      try {
        final doc = await FirebaseFirestore.instance.collection('users').doc(fromUserId).get();
        if (doc.exists && doc.data() != null) {
          callerName = doc.data()!['name'] ?? callerName;
        }
      } catch (e) {
        debugPrint('Error fetching caller name: $e');
      }
    }

    final params = CallKitParams(
      id: callId,
      nameCaller: callerName,
      appName: 'VactOnline',
      avatar: 'https://i.pravatar.cc/100',
      handle: 'Video Call',
      type: callType == 'video' ? 1 : 0,
      duration: 30000,
      extra: <String, dynamic>{'userId': fromUserId},
      android: const AndroidParams(
        isCustomNotification: true,
        isShowLogo: false,
        ringtonePath: 'system_ringtone_default',
        backgroundColor: '#0F0F1A',
        backgroundUrl: 'assets/test.png',
        actionColor: '#4CAF50',
        textAccept: 'Accept',
        textDecline: 'Decline',
      ),
      ios: const IOSParams(
        iconName: 'CallKitIcon',
        handleType: '',
        supportsVideo: true,
        maximumCallGroups: 2,
        maximumCallsPerCallGroup: 1,
        audioSessionMode: 'default',
        audioSessionActive: true,
        audioSessionPreferredSampleRate: 44100.0,
        audioSessionPreferredIOBufferDuration: 0.005,
        supportsDTMF: true,
        supportsHolding: true,
        supportsGrouping: false,
        supportsUngrouping: false,
        ringtonePath: 'system_ringtone_default',
      ),
    );
    await FlutterCallkitIncoming.showCallkitIncoming(params);
  }
}


// NOTE: Firebase.initializeApp() is called after you run:
//   flutterfire configure
// which generates lib/firebase_options.dart.
// Until then, Firebase Auth + Cloud Functions calls will fail gracefully.

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ─── Uncomment after running `flutterfire configure` ─────────────────────
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  // ─────────────────────────────────────────────────────────────────────────

  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  runApp(const MyApp());
}

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  @override
  void initState() {
    super.initState();
    _listenToCallKitEvents();
  }

  void _listenToCallKitEvents() {
    FlutterCallkitIncoming.onEvent.listen((CallEvent? event) async {
      switch (event) {
        case CallEventActionCallAccept():
          final callId = event.callKitParams.id;
          final currentUid = FirebaseAuth.instance.currentUser?.uid;
          if (currentUid != null) {
            try {
              await VactService.instance.connect();
              final vact = VactService.instance.vact;
              
              // Find the call in incomingCalls
              var incomingCall = VactService.instance.latestIncomingCalls
                  .where((c) => c.id == callId)
                  .firstOrNull;

              if (incomingCall == null) {
                final incomingCallList = await vact.incomingCalls().firstWhere(
                  (calls) => calls.any((c) => c.id == callId), 
                  orElse: () => <VactIncomingCall>[]
                );
                if (incomingCallList.isNotEmpty) {
                  incomingCall = incomingCallList.firstWhere((c) => c.id == callId);
                }
              }
              
              if (incomingCall != null) {
                final call = await vact.accept(incomingCall);
                
                // Wait for the navigator to be ready (e.g. if app was cold booted)
                while (navigatorKey.currentState == null) {
                  await Future.delayed(const Duration(milliseconds: 50));
                }
                
                navigatorKey.currentState?.pushNamed('/call', arguments: call);
              }
            } catch (e) {
              debugPrint('Failed to accept callkit call: $e');
            }
          }
          break;
        case CallEventActionCallDecline():
          final callId = event.callKitParams.id;
          final fromUserId = event.callKitParams.extra?['userId'] as String?;
          final currentUid = FirebaseAuth.instance.currentUser?.uid;
          if (currentUid != null && fromUserId != null) {
            CallLogService.saveCallLog(
              callerUid: fromUserId,
              callerName: event.callKitParams.nameCaller ?? fromUserId,
              calleeUid: currentUid,
              calleeName: 'Me',
              type: event.callKitParams.type == 1 ? 'video' : 'audio',
              status: 'declined',
              duration: 0,
              endreason: 'declined',
            );
            try {
              await VactService.instance.connect();
              final vact = VactService.instance.vact;
              final incomingCallList = await vact.incomingCalls().firstWhere(
                (calls) => calls.any((c) => c.id == callId), 
                orElse: () => <VactIncomingCall>[]
              );
              if (incomingCallList.isNotEmpty) {
                final incomingCall = incomingCallList.firstWhere((c) => c.id == callId);
                await vact.decline(incomingCall);
              }
            } catch (e) {
              debugPrint('Failed to decline callkit call: $e');
            }
          }
          break;
        default:
          break;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
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
