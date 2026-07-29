import 'dart:async';

import 'package:flutter/material.dart';
import 'package:vact_sdk/vact_sdk.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../services/call_log_service.dart';

/// Outgoing ringing screen. Receives the VactCall object via route arguments.
class RingingScreen extends StatefulWidget {
  const RingingScreen({super.key});

  @override
  State<RingingScreen> createState() => _RingingScreenState();
}

class _RingingScreenState extends State<RingingScreen> {
  VactCall? _call;
  late final StreamSubscription<VactCallState> _stateSub;
  VactCallState _state = VactCallState.ringing;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final call = ModalRoute.of(context)?.settings.arguments as VactCall?;
    if (call != null && _call == null) {
      _call = call;
      _stateSub = call.states.listen((state) {
        if (!mounted) return;
        setState(() => _state = state);
        switch (state) {
          case VactCallState.connected:
            // Callee answered — move to the active call screen
            Navigator.pushReplacementNamed(context, '/call', arguments: call);
            break;
          case VactCallState.ended:
          case VactCallState.failed:
            // Rejected or timed-out — pop back to home
            final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
            CallLogService.saveCallLog(
              callerUid: currentUid, // We are the caller
              callerName: 'Me',
              calleeUid: call.otherUserId,
              calleeName: call.otherUserId,
              type: 'video', // Assuming video
              status: 'declined', // or missed
              duration: 0,
              endreason: state == VactCallState.ended ? 'declined' : 'failed',
            );
            Navigator.pop(context);
            break;
          default:
            break;
        }
      });
    }
  }

  @override
  void dispose() {
    _stateSub.cancel();
    super.dispose();
  }

  String get _statusText {
    switch (_state) {
      case VactCallState.ringing:
        return 'Ringing…';
      case VactCallState.connecting:
        return 'Connecting…';
      case VactCallState.connected:
        return 'Connected';
      case VactCallState.ended:
        return 'Call Ended';
      case VactCallState.failed:
        return 'Call Failed';
      default:
        return 'Calling…';
    }
  }

  Color get _statusColor {
    switch (_state) {
      case VactCallState.connected:
        return const Color(0xFF00C9B1);
      case VactCallState.ended:
      case VactCallState.failed:
        return Colors.redAccent;
      default:
        return Colors.white70;
    }
  }

  @override
  Widget build(BuildContext context) {
    final calleeName = _call?.otherUserId ?? 'Unknown';

    return Scaffold(
      backgroundColor: const Color(0xFF0D0D1A),
      body: SafeArea(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Spacer(),
            // Avatar
            Center(
              child: Container(
                width: 130,
                height: 130,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const LinearGradient(
                    colors: [Color(0xFF6C63FF), Color(0xFF8B85FF)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF6C63FF).withValues(alpha: 0.5),
                      blurRadius: 40,
                      spreadRadius: 10,
                    ),
                  ],
                ),
                child: Center(
                  child: Text(
                    calleeName.isNotEmpty ? calleeName[0].toUpperCase() : '?',
                    style: const TextStyle(
                      fontSize: 54,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 28),
            Text(
              calleeName,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 30, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            Text(
              _statusText,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16, color: _statusColor),
            ),
            const Spacer(),
            // Cancel button
            Padding(
              padding: const EdgeInsets.only(bottom: 60),
              child: Column(
                children: [
                  GestureDetector(
                    onTap: () {
                      _call?.cancel();
                      Navigator.pop(context);
                    },
                    child: Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        color: Colors.red,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.red.withValues(alpha: 0.4),
                            blurRadius: 24,
                            spreadRadius: 4,
                          ),
                        ],
                      ),
                      child: const Icon(Icons.call_end, size: 34, color: Colors.white),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text('Cancel', style: TextStyle(color: Colors.white54, fontSize: 15)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
