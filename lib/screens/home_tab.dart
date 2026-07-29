import 'dart:async';
import 'dart:ui';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:vact_sdk/vact_sdk.dart';

import '../services/vact_service.dart';
import '../services/call_log_service.dart';

/// The Home tab — shows the list of other users to call.
class HomeTab extends StatefulWidget {
  const HomeTab({super.key});

  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<HomeTab> with WidgetsBindingObserver {
  late final StreamSubscription<List<VactIncomingCall>> _incomingSub;

  String _userName = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _updatePresence('Online');
    _loadUserName();
    _requestPermissions();
    _listenForIncomingCalls();
  }

  Future<void> _loadUserName() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _userName = prefs.getString('user_name') ?? 'User';
      });
    }
  }

  Future<void> _requestPermissions() async {
    await [Permission.microphone, Permission.camera].request();
  }

  Future<void> _updatePresence(String status) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      try {
        await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .update({'status': status});
      } catch (_) {}
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _updatePresence('Online');
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _updatePresence('Offline');
    }
  }

  Route? _incomingCallRoute;
  VactIncomingCall? _lastIncoming;
  bool _callHandled = false;

  void _listenForIncomingCalls() {
    _incomingSub = VactService.instance.vact.incomingCalls().listen((calls) {
      if (!mounted) return;
      
      if (calls.isEmpty) {
        if (_incomingCallRoute != null) {
          Navigator.of(context).removeRoute(_incomingCallRoute!);
          _incomingCallRoute = null;
        }
        if (_lastIncoming != null && !_callHandled) {
          final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
          CallLogService.saveCallLog(
            callerUid: _lastIncoming!.fromUserId,
            callerName: _lastIncoming!.callerName.isNotEmpty ? _lastIncoming!.callerName : _lastIncoming!.fromUserId,
            calleeUid: currentUid,
            calleeName: 'Me',
            type: _lastIncoming!.type == VactCallType.video ? 'video' : 'audio',
            status: 'missed',
            duration: 0,
            endreason: 'missed',
          );
        }
        _lastIncoming = null;
        return;
      }

      if (_incomingCallRoute == null) {
        final incoming = calls.first;
        _lastIncoming = incoming;
        _callHandled = false;
        
        _incomingCallRoute = MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => _IncomingCallOverlay(
            incoming: incoming,
            vact: VactService.instance.vact,
            onHandled: () {
              _callHandled = true;
            },
          ),
        );
        Navigator.of(context).push(_incomingCallRoute!).then((_) {
          _incomingCallRoute = null;
        });
      }
    });
  }

  Future<void> _placeCall(String targetUserId) async {
    print('starttttttttt');
    HapticFeedback.lightImpact();
    print('1111111111111');
    try {
      print('22222222222222');
      await _updatePresence('In a Call');
      final call = await VactService.instance.vact.call(
        targetUserId,
        video: true,
      );
      print('3333333333333333');
      if (!mounted) return;
      print('4444444444444444');
      await Navigator.pushNamed(context, '/call', arguments: call);
      print('55555555555555');
      await _updatePresence('Online');
      print('6666666666666666666');
    } on VactException catch (e,s) {
      print('jjjjjjjjjjjjjjjjjjjjjjjjj');
      print(e.toString());
      print(s.toString());
      HapticFeedback.heavyImpact();
      await _updatePresence('Online');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Call failed: ${e.message}'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'Online':
        return const Color(0xFF00C9B1);
      case 'Away':
        return const Color(0xFFF5A623);
      default:
        return Colors.white24;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _incomingSub.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF0F0F1A), Color(0xFF1A1A2E)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
              child: Row(
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ShaderMask(
                        shaderCallback: (bounds) => const LinearGradient(
                          colors: [Color(0xFF00E5FF), Color(0xFF8A2BE2)],
                        ).createShader(bounds),
                        child: Text(
                          'Welcome, $_userName',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 22,
                            letterSpacing: -0.5,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      Text(
                        user?.email ?? '',
                        style: const TextStyle(fontSize: 12, color: Colors.white54),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            // Connected status banner
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              margin: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF00E5FF).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                    color: const Color(0xFF00E5FF).withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: const BoxDecoration(
                      color: Color(0xFF00E5FF),
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(color: Color(0xFF00E5FF), blurRadius: 10),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Text(
                    'VACT Connected — ready for calls',
                    style: TextStyle(
                      color: Color(0xFF00E5FF),
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance
                    .collection('users')
                    .where('uid', isNotEqualTo: user?.uid)
                    .snapshots(),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(
                        child: CircularProgressIndicator(
                            color: Color(0xFF8A2BE2)));
                  }
                  if (snapshot.hasError) {
                    return const Center(
                      child: Text('Error loading users',
                          style: TextStyle(color: Colors.white54)),
                    );
                  }

                  final docs = snapshot.data?.docs ?? [];
                  if (docs.isEmpty) {
                    return const Center(
                      child: Text('No other users found',
                          style:
                              TextStyle(color: Colors.white54, fontSize: 16)),
                    );
                  }

                  return ListView.builder(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    itemCount: docs.length,
                    itemBuilder: (context, index) {
                      final data =
                          docs[index].data() as Map<String, dynamic>;
                      final contactName =
                          data['name'] as String? ?? 'Unknown';
                      final contactUid = data['uid'] as String;
                      final status = data['status'] as String? ?? 'Offline';
                      print('33333333333333${contactUid}');

                      return Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.05),
                          borderRadius: index.isEven
                              ? const BorderRadius.only(
                                  topLeft: Radius.circular(40),
                                  bottomRight: Radius.circular(40),
                                  topRight: Radius.circular(10),
                                  bottomLeft: Radius.circular(10))
                              : const BorderRadius.only(
                                  topRight: Radius.circular(40),
                                  bottomLeft: Radius.circular(40),
                                  topLeft: Radius.circular(10),
                                  bottomRight: Radius.circular(10)),
                          border: Border.all(
                              color: Colors.white.withValues(alpha: 0.1)),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.1),
                              blurRadius: 20,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 12),
                          leading: Stack(
                            children: [
                              Container(
                                width: 52,
                                height: 52,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  gradient: const LinearGradient(
                                    colors: [
                                      Color(0xFF8A2BE2),
                                      Color(0xFF00E5FF)
                                    ],
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: const Color(0xFF8A2BE2)
                                          .withValues(alpha: 0.4),
                                      blurRadius: 12,
                                    ),
                                  ],
                                ),
                                alignment: Alignment.center,
                                child: Text(
                                  contactName.isNotEmpty
                                      ? contactName[0].toUpperCase()
                                      : '?',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 22,
                                  ),
                                ),
                              ),
                              Positioned(
                                bottom: 0,
                                right: 0,
                                child: Container(
                                  width: 14,
                                  height: 14,
                                  decoration: BoxDecoration(
                                    color: _statusColor(status),
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                        color: const Color(0xFF141421),
                                        width: 2),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          title: Text(
                            contactName,
                            style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                                letterSpacing: -0.3),
                          ),
                          subtitle: Padding(
                            padding: const EdgeInsets.only(top: 4.0),
                            child: Text(
                              status,
                              style: TextStyle(
                                color: _statusColor(status),
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                          trailing: status == 'Online'
                              ? GestureDetector(
                                  onTap: () => _placeCall(contactUid),
                                  child: Container(
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      gradient: const LinearGradient(
                                        colors: [
                                          Color(0xFF8A2BE2),
                                          Color(0xFF00E5FF)
                                        ],
                                      ),
                                      borderRadius: BorderRadius.circular(16),
                                      boxShadow: [
                                        BoxShadow(
                                          color: const Color(0xFF8A2BE2)
                                              .withValues(alpha: 0.4),
                                          blurRadius: 12,
                                          offset: const Offset(0, 4),
                                        ),
                                      ],
                                    ),
                                    child: const Icon(Icons.videocam,
                                        color: Colors.white, size: 22),
                                  ),
                                )
                              : const SizedBox(width: 48, height: 48),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Incoming call overlay ───────────────────────────────────────────────────

class _IncomingCallOverlay extends StatefulWidget {
  const _IncomingCallOverlay({super.key, required this.incoming, required this.vact, required this.onHandled});
  final VactIncomingCall incoming;
  final Vact vact;
  final VoidCallback onHandled;

  @override
  State<_IncomingCallOverlay> createState() => _IncomingCallOverlayState();
}

class _IncomingCallOverlayState extends State<_IncomingCallOverlay> {
  String _callerName = '';

  @override
  void initState() {
    super.initState();
    _fetchCallerName();
  }

  Future<void> _fetchCallerName() async {
    if (widget.incoming.callerName.isNotEmpty && widget.incoming.callerName != widget.incoming.fromUserId) {
      if (mounted) setState(() => _callerName = widget.incoming.callerName);
      return;
    }
    
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(widget.incoming.fromUserId)
          .get();
      if (doc.exists && mounted) {
        setState(() {
          _callerName = doc.data()?['name'] ?? 'Unknown Caller';
        });
      } else {
        if (mounted) setState(() => _callerName = 'Unknown Caller');
      }
    } catch (e) {
      if (mounted) setState(() => _callerName = 'Unknown Caller');
    }
  }

  Future<void> _accept(BuildContext context) async {
    HapticFeedback.lightImpact();
    try {
      widget.onHandled();
      final call = await widget.vact.accept(widget.incoming);
      if (!context.mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => _CallScreenWrapper(call: call)),
      );
    } on VactException catch (e) {
      HapticFeedback.heavyImpact();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message), backgroundColor: Colors.red),
      );
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isVideo = widget.incoming.type == VactCallType.video;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          Positioned.fill(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
              child: Container(color: Colors.black.withValues(alpha: 0.6)),
            ),
          ),
          SafeArea(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Spacer(),
                Center(
                  child: Container(
                    width: 120,
                    height: 120,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: const LinearGradient(
                        colors: [Color(0xFF00C9B1), Color(0xFF6C63FF)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF00C9B1).withValues(alpha: 0.4),
                          blurRadius: 32,
                          spreadRadius: 8,
                        ),
                      ],
                    ),
                    child:
                        const Icon(Icons.person, size: 60, color: Colors.white),
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  _callerName.isEmpty ? 'Loading...' : _callerName,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 30, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(
                  isVideo ? 'Incoming Video Call' : 'Incoming Call',
                  textAlign: TextAlign.center,
                  style:
                      const TextStyle(color: Colors.white54, fontSize: 16),
                ),
                const Spacer(),
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 60, vertical: 40),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      Column(
                        children: [
                          GestureDetector(
                            onTap: () async {
                              HapticFeedback.lightImpact();
                              try {
                                widget.onHandled();
                                final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
                                CallLogService.saveCallLog(
                                  callerUid: widget.incoming.fromUserId,
                                  callerName: _callerName,
                                  calleeUid: currentUid,
                                  calleeName: 'Me',
                                  type: widget.incoming.type == VactCallType.video ? 'video' : 'audio',
                                  status: 'declined',
                                  duration: 0,
                                  endreason: 'declined',
                                );
                                await widget.vact.decline(widget.incoming);
                              } on VactException catch (e) {
                                debugPrint('Error declining call: $e');
                              }
                              if (context.mounted) {
                                Navigator.of(context).pop();
                              }
                            },
                            child: Container(
                              width: 72,
                              height: 72,
                              decoration: BoxDecoration(
                                color: Colors.redAccent,
                                shape: BoxShape.circle,
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.redAccent
                                        .withValues(alpha: 0.5),
                                    blurRadius: 24,
                                    spreadRadius: 4,
                                  ),
                                ],
                              ),
                              child: const Icon(Icons.call_end,
                                  size: 32, color: Colors.white),
                            ),
                          ),
                          const SizedBox(height: 12),
                          const Text('Decline',
                              style: TextStyle(
                                  color: Colors.white70,
                                  fontWeight: FontWeight.bold)),
                        ],
                      ),
                      Column(
                        children: [
                          GestureDetector(
                            onTap: () => _accept(context),
                            child: Container(
                              width: 72,
                              height: 72,
                              decoration: BoxDecoration(
                                gradient: const LinearGradient(
                                  colors: [Color(0xFF8A2BE2), Color(0xFF00E5FF)],
                                ),
                                shape: BoxShape.circle,
                                boxShadow: [
                                  BoxShadow(
                                    color: const Color(0xFF00E5FF)
                                        .withValues(alpha: 0.5),
                                    blurRadius: 24,
                                    spreadRadius: 4,
                                  ),
                                ],
                              ),
                              child: Icon(
                                isVideo ? Icons.videocam : Icons.call,
                                size: 32,
                                color: Colors.white,
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          const Text('Accept',
                              style: TextStyle(
                                  color: Colors.white70,
                                  fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CallScreenWrapper extends StatelessWidget {
  const _CallScreenWrapper({required this.call});
  final VactCall call;

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Navigator.of(context).pushReplacementNamed('/call', arguments: call);
    });
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}
