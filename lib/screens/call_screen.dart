import 'dart:async';
import 'dart:ui';
import 'package:flutter/services.dart';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:vact_sdk/vact_sdk.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../services/call_log_service.dart';

/// Active video call screen. Receives VactCall via route arguments.
class CallScreen extends StatefulWidget {
  const CallScreen({super.key});

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  VactCall? _call;
  final _localRenderer = RTCVideoRenderer();
  final _remoteRenderer = RTCVideoRenderer();
  late final StreamSubscription<VactCallState> _stateSub;
  StreamSubscription<MediaStream>? _remoteStreamSub;

  bool _muted = false;
  bool _cameraOn = true;
  VactCallState _state = VactCallState.connecting;
  DateTime? _connectedAt;
  Timer? _timer;
  String _calleeName = '';

  bool _renderersInitialized = false;

  @override
  void initState() {
    super.initState();
    _initRenderers();
  }

  Future<void> _initRenderers() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
    if (mounted) {
      setState(() {
        _renderersInitialized = true;
      });
      _attachStreams();
    }
  }

  void _attachStreams() {
    if (_renderersInitialized && _call != null) {
      _localRenderer.srcObject = _call!.localStream;
      _remoteRenderer.srcObject = _call!.remoteStream;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final call = ModalRoute.of(context)?.settings.arguments as VactCall?;
    if (call != null && _call == null) {
      _call = call;
      _attachStreams();

      FirebaseFirestore.instance
          .collection('users')
          .doc(call.otherUserId)
          .get()
          .then((doc) {
        if (mounted && doc.exists) {
          setState(() {
            _calleeName = doc.data()?['name'] as String? ?? '';
          });
        }
      });

      _remoteStreamSub = call.onRemoteStream.listen((stream) {
        if (!mounted) return;
        setState(() {
          _remoteRenderer.srcObject = stream;
        });
      });

      _stateSub = call.states.listen((state) {
        if (!mounted) return;
        setState(() => _state = state);
        if (state == VactCallState.connected && _connectedAt == null) {
          _connectedAt = DateTime.now();
          _timer = Timer.periodic(const Duration(seconds: 1), (_) {
            if (mounted) setState(() {});
          });
        }
        if (state == VactCallState.ended || state == VactCallState.failed) {
          _timer?.cancel();
          final duration = _connectedAt != null
              ? DateTime.now().difference(_connectedAt!).inSeconds
              : 0;
          
          final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
          
          CallLogService.saveCallLog(
            callerUid: call.isCaller ? currentUid : call.otherUserId,
            callerName: call.isCaller ? 'Me' : call.otherUserId, // Could pass real names if available
            calleeUid: call.isCaller ? call.otherUserId : currentUid,
            calleeName: call.isCaller ? call.otherUserId : 'Me',
            type: 'video', // Assuming video for CallScreen since camera is initialized
            status: state == VactCallState.ended ? 'connected' : 'failed',
            duration: duration,
            endreason: state == VactCallState.ended ? 'completed' : 'failed',
          );

          Navigator.of(context).popUntil((route) => route.isFirst);
        }
      });

      // Use speaker for video calls
      call.setAudioRoute(VactAudioRoute.speaker);
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _stateSub.cancel();
    _remoteStreamSub?.cancel();
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    try {
      final call = _call;
      if (call != null) {
        if (!call.isCaller) {
          call.end();
        } else if (_state == VactCallState.ringing || _state == VactCallState.connecting) {
          call.cancel();
        } else {
          call.end();
        }
      }
    } catch (e) {
      debugPrint('Error terminating call in dispose: $e');
    }
    super.dispose();
  }

  String get _statusLabel => switch (_state) {
    VactCallState.ringing => 'Ringing…',
    VactCallState.connecting => 'Connecting…',
    VactCallState.connected => 'Connected',
    VactCallState.reconnecting => 'Reconnecting…',
    VactCallState.ended => 'Call ended',
    VactCallState.failed => 'Call failed',
  };

  @override
  Widget build(BuildContext context) {
    final call = _call;
    final calleeId = call?.otherUserId ?? '';
    final displayName = _calleeName.isNotEmpty ? _calleeName : calleeId;

    String timerText = '';
    if (_connectedAt != null) {
      final duration = DateTime.now().difference(_connectedAt!);
      String twoDigits(int n) => n.toString().padLeft(2, '0');
      timerText = '${twoDigits(duration.inMinutes)}:${twoDigits(duration.inSeconds.remainder(60))}';
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Remote video — full screen
          Positioned.fill(
            child: call != null
                ? RTCVideoView(_remoteRenderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover)
                : Container(
                    color: const Color(0xFF1A1A2E),
                    child: const Center(
                      child: CircularProgressIndicator(color: Color(0xFF6C63FF)),
                    ),
                  ),
          ),

          // Dark gradient overlay at top and bottom
          Positioned.fill(
            child: DecoratedBox(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.center,
                  colors: [Colors.black54, Colors.transparent],
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: DecoratedBox(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.center,
                  colors: [Colors.black87, Colors.transparent],
                ),
              ),
            ),
          ),

          // Local video preview — top right
          if (_cameraOn && call != null)
            Positioned(
              top: 56,
              right: 16,
              width: 120,
              height: 180,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.15), width: 1),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.4),
                      blurRadius: 20,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(15),
                  child: RTCVideoView(_localRenderer, mirror: true, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
                ),
              ),
            ),

          // Callee name + status — top left
          Positioned(
            top: 56,
            left: 20,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  displayName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    shadows: [Shadow(color: Colors.black45, blurRadius: 8)],
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _connectedAt != null ? timerText : _statusLabel,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 16,
                    shadows: [Shadow(color: Colors.black45, blurRadius: 6)],
                  ),
                ),
              ],
            ),
          ),

          // Controls bar — bottom
          Positioned(
            left: 24,
            right: 24,
            bottom: 40,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(32),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(32),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // Mute
                      _ControlButton(
                        icon: _muted ? Icons.mic_off : Icons.mic,
                        color: _muted ? Colors.redAccent : Colors.white.withValues(alpha: 0.1),
                        onTap: () async {
                          setState(() => _muted = !_muted);
                          await call?.setMicrophoneEnabled(!_muted);
                        },
                      ),
                      // Camera toggle
                      _ControlButton(
                        icon: _cameraOn ? Icons.videocam : Icons.videocam_off,
                        color: _cameraOn ? Colors.white.withValues(alpha: 0.1) : Colors.redAccent,
                        onTap: () async {
                          setState(() => _cameraOn = !_cameraOn);
                          await call?.setCameraEnabled(_cameraOn);
                        },
                      ),
                      // Switch camera
                      _ControlButton(
                        icon: Icons.cameraswitch,
                        color: Colors.white.withValues(alpha: 0.1),
                        onTap: () => call?.switchCamera(),
                      ),
                      // End call — larger red button
                      GestureDetector(
                        onTap: () {
                          HapticFeedback.lightImpact();
                          try {
                            if (call != null) {
                              if (!call.isCaller) {
                                call.end();
                              } else if (_state == VactCallState.ringing || _state == VactCallState.connecting) {
                                call.cancel();
                              } else {
                                call.end();
                              }
                            }
                          } catch (e) {
                            debugPrint('Error hanging up call: $e');
                          }
                          Navigator.of(context).popUntil((route) => route.isFirst);
                        },
                        child: Container(
                          width: 60,
                          height: 60,
                          decoration: BoxDecoration(
                            color: Colors.redAccent,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: Colors.redAccent.withValues(alpha: 0.5),
                                blurRadius: 16,
                                spreadRadius: 2,
                              ),
                            ],
                          ),
                          child: const Icon(Icons.call_end, size: 28, color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ControlButton extends StatelessWidget {
  const _ControlButton({
    required this.icon,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        onTap();
      },
      child: Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: Colors.white, size: 24),
      ),
    );
  }
}
