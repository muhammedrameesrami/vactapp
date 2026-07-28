import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

/// Handles FCM token lifecycle for a signed-in user.
///
/// All methods are **fire-and-forget** — they silently swallow errors
/// so that FCM failures never break authentication or navigation.
class FcmService {
  FcmService._();

  static final FirebaseMessaging _fcm = FirebaseMessaging.instance;
  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  // ─── Permission ────────────────────────────────────────────────────────────

  /// Requests notification permission. Returns false if the plugin is
  /// unavailable or if permission is denied. Never throws.
  static Future<bool> requestPermission() async {
    try {
      final settings = await _fcm.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      return settings.authorizationStatus == AuthorizationStatus.authorized ||
          settings.authorizationStatus  == AuthorizationStatus.provisional;
    } catch (e,s) {
      print('requesssssssssss');
      print(s.toString());
      // Handles MissingPluginException on first install before full rebuild.
      print('[FcmService] requestPermission failed (non-fatal): $e');
      return false;
    }
  }

  // ─── Token retrieval ───────────────────────────────────────────────────────

  /// Returns the current FCM token, or `null` if unavailable. Never throws.
  static Future<String?> getToken() async {
    try {
      return await _fcm.getToken();
    } catch (e,s) {
      print('get tokeeeeeeeeeeeeee');
      print(s.toString());
      print('[FcmService] getToken failed (non-fatal): $e');
      return null;
    }
  }

  // ─── Login flow ────────────────────────────────────────────────────────────

  /// Called after a successful login.
  ///
  /// Gets the current FCM token and adds it to `fcmTokens` via arrayUnion:
  /// - **Same token**: no-op (Firestore deduplicates).
  /// - **New/expired token**: appended to the list.
  ///
  /// Silently skips if FCM plugin is unavailable (e.g. before a clean rebuild).
  static Future<void> syncTokenOnLogin(String uid) async {
    try {
      await requestPermission();
      final token = await getToken();
      if (token == null) return;

      // arrayUnion: no-op if token already in list, appends if new or expired.
      await _db.collection('users').doc(uid).update({
        'fcmTokens': FieldValue.arrayUnion([token]),
      });
    } catch (e,s) {
      print('sync tokennnnnnnnnnnnnnnnnnn');
      print(s.toString());
      print('[FcmService] syncTokenOnLogin failed (non-fatal): $e');
    }
  }

  // ─── Token refresh listener ────────────────────────────────────────────────

  /// Listens for FCM token refreshes while the app is running.
  /// Silently ignores errors — never throws to the caller.
  static void listenForTokenRefresh(String uid) {
    try {
      _fcm.onTokenRefresh.listen(
        (newToken) async {
          try {
            await _db.collection('users').doc(uid).update({
              'fcmTokens': FieldValue.arrayUnion([newToken]),
            });
          } catch (e,s) {
            print('token refresh update failed');
            print(s.toString());
            print('[FcmService] token refresh update failed (non-fatal): $e');
          }
        },
        onError: (e,s) => print('refresh tokennnnnnnnnnnnnnnnnnn'),
      );
    } catch (e,s) {

      print('[FcmService] listenForTokenRefresh failed (non-fatal): $e');
    }
  }
}

