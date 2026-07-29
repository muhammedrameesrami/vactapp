
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

/// Displays the current user's call history stored in Firestore.
///
/// Expected Firestore collection: `call_history` (documents per user)
/// Each document field: `calls` → List of maps with keys:
///   contactName, contactUid, type (video/audio), status (missed/received/outgoing),
///   timestamp (Timestamp), duration (int seconds)
///
/// Falls back gracefully if the collection / documents don't exist yet.
class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

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
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ─── Header ──────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ShaderMask(
                    shaderCallback: (bounds) => const LinearGradient(
                      colors: [Color(0xFF00E5FF), Color(0xFF8A2BE2)],
                    ).createShader(bounds),
                    child: const Text(
                      'Call History',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                        letterSpacing: -0.5,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Your recent video & audio calls',
                    style: TextStyle(color: Colors.white38, fontSize: 13),
                  ),
                ],
              ),
            ),

            // ─── Call list ───────────────────────────────────────────────
            Expanded(
              child: StreamBuilder<QuerySnapshot>(
                stream: user == null
                    ? const Stream.empty()
                    : FirebaseFirestore.instance
                        .collection('call_history')
                        .where('participants', arrayContains: user.uid)
                        .orderBy('timestamp', descending: true)
                        .limit(100)
                        .snapshots(),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(
                      child: CircularProgressIndicator(
                          color: Color(0xFF8A2BE2)),
                    );
                  }

                  if (snapshot.hasError) {
                    // Show empty state — collection may not exist yet
                    return _EmptyHistory();
                  }

                  final docs = snapshot.data?.docs ?? [];
                  if (docs.isEmpty) return _EmptyHistory();

                  return ListView.builder(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 4),
                    itemCount: docs.length,
                    itemBuilder: (context, index) {
                      final data =
                          docs[index].data() as Map<String, dynamic>;
                      return _CallHistoryCard(
                          data: data, currentUid: user?.uid ?? '');
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

// ─── Empty state ──────────────────────────────────────────────────────────────

class _EmptyHistory extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(
                colors: [Color(0xFF8A2BE2), Color(0xFF00E5FF)],
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF8A2BE2).withValues(alpha: 0.35),
                  blurRadius: 28,
                  spreadRadius: 4,
                ),
              ],
            ),
            child: const Icon(Icons.history_rounded,
                size: 48, color: Colors.white),
          ),
          const SizedBox(height: 24),
          const Text(
            'No call history yet',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Your video and audio calls\nwill appear here.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white38, fontSize: 14),
          ),
        ],
      ),
    );
  }
}

// ─── Single call card ─────────────────────────────────────────────────────────

class _CallHistoryCard extends StatelessWidget {
  const _CallHistoryCard(
      {required this.data, required this.currentUid});
  final Map<String, dynamic> data;
  final String currentUid;

  @override
  Widget build(BuildContext context) {
    final callerUid = data['callerUid'] as String? ?? '';
    final callerName = data['callerName'] as String? ?? 'Unknown';
    final calleeName = data['calleeName'] as String? ?? 'Unknown';
    final type = data['type'] as String? ?? 'video';
    final status = data['status'] as String? ?? 'missed';
    final Timestamp? ts = data['timestamp'] as Timestamp?;
    final int duration = (data['duration'] as int?) ?? 0;

    final isOutgoing = callerUid == currentUid;
    final contactName = isOutgoing ? calleeName : callerName;

    final DateTime? callTime = ts?.toDate();

    final Color statusColor;
    final IconData statusIcon;
    switch (status) {
      case 'missed':
        statusColor = Colors.redAccent;
        statusIcon = Icons.call_missed_rounded;
        break;
      case 'received':
        statusColor = const Color(0xFF00C9B1);
        statusIcon = Icons.call_received_rounded;
        break;
      default: // outgoing
        statusColor = const Color(0xFF00E5FF);
        statusIcon = Icons.call_made_rounded;
    }

    String formatDuration(int seconds) {
      if (seconds == 0) return 'Not answered';
      final m = seconds ~/ 60;
      final s = seconds % 60;
      return m > 0 ? '${m}m ${s}s' : '${s}s';
    }

    String formatTime(DateTime? dt) {
      if (dt == null) return '';
      final now = DateTime.now();
      final diff = now.difference(dt);
      if (diff.inDays == 0) {
        return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
      } else if (diff.inDays == 1) {
        return 'Yesterday';
      } else if (diff.inDays < 7) {
        const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
        return days[dt.weekday - 1];
      } else {
        return '${dt.day}/${dt.month}/${dt.year}';
      }
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 20,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        leading: Stack(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: isOutgoing
                      ? [const Color(0xFF00E5FF), const Color(0xFF8A2BE2)]
                      : [const Color(0xFF8A2BE2), const Color(0xFF00C9B1)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                boxShadow: [
                  BoxShadow(
                    color: statusColor.withValues(alpha: 0.3),
                    blurRadius: 10,
                  ),
                ],
              ),
              alignment: Alignment.center,
              child: Text(
                contactName.isNotEmpty ? contactName[0].toUpperCase() : '?',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 20,
                ),
              ),
            ),
            Positioned(
              bottom: 0,
              right: 0,
              child: Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  color: const Color(0xFF0B0B13),
                  shape: BoxShape.circle,
                  border: Border.all(color: statusColor, width: 1.5),
                ),
                child: Icon(statusIcon, size: 10, color: statusColor),
              ),
            ),
          ],
        ),
        title: Text(
          contactName,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 15,
            color: Colors.white,
          ),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(
            children: [
              Icon(
                type == 'video' ? Icons.videocam_rounded : Icons.call_rounded,
                size: 13,
                color: Colors.white38,
              ),
              const SizedBox(width: 4),
              Text(
                '${type == 'video' ? 'Video' : 'Voice'} · ${formatDuration(duration)}',
                style:
                    const TextStyle(color: Colors.white38, fontSize: 12),
              ),
            ],
          ),
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              formatTime(callTime),
              style: TextStyle(
                fontSize: 12,
                color: Colors.white38,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              isOutgoing ? 'Outgoing' : (status == 'missed' ? 'Missed' : 'Incoming'),
              style: TextStyle(
                fontSize: 11,
                color: statusColor,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
