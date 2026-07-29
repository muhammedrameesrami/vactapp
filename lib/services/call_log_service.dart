import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class CallLogService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  static Future<void> saveCallLog({
    required String callerUid,
    required String callerName,
    required String calleeUid,
    required String calleeName,
    required String type, // 'video' or 'audio'
    required String status, // 'connected', 'declined', 'missed', etc.
    required int duration, // in seconds
    String? setup,
    String? route,
    String? network,
    String? endreason,
  }) async {
    try {
      final data = {
        'callerUid': callerUid,
        'callerName': callerName,
        'calleeUid': calleeUid,
        'calleeName': calleeName,
        'participants': [callerUid, calleeUid],
        'type': type,
        'status': status,
        'duration': duration,
        'timestamp': FieldValue.serverTimestamp(),
      };

      if (setup != null) data['setup'] = setup;
      if (route != null) data['route'] = route;
      if (network != null) data['network'] = network;
      if (endreason != null) data['endreason'] = endreason;

      await _firestore.collection('call_history').add(data);
    } catch (e) {
      print('Failed to save call log: $e');
    }
  }
}
