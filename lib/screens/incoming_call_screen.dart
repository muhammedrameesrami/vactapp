// This screen is kept as a named route for direct navigation if needed.
// The real incoming call UI is handled by _IncomingCallOverlay in home_screen.dart
// which receives the VactIncomingCall object directly from the SDK listener.
import 'package:flutter/material.dart';

class IncomingCallScreen extends StatelessWidget {
  const IncomingCallScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Text('Incoming call handling is active on the home screen.'),
      ),
    );
  }
}
