import 'package:cloud_functions/cloud_functions.dart';
import 'package:vact_sdk/vact_sdk.dart';

/// Singleton service that manages the VACT client lifecycle.
/// Call [connect] after the user has logged in with Firebase Auth.
class VactService {
  VactService._();
  static final VactService instance = VactService._();

  // Replace with your VACT App ID from https://vact.online dashboard
  // NOTE: Do not use your Firebase App ID (1:...) here.
  static const String _appId = 'vact_app_fe30b4770cb22e7f646a459e';

  Vact? _vactInstance;
  bool _initialized = false;

  Vact get vact => _vactInstance!;

  /// Call once after Firebase Auth sign-in. Fetches a one-time token
  /// from the Firebase Cloud Function and connects to VACT.
  Future<void> connect() async {
    if (_initialized) return;

    // Initialise the VACT client (public App ID only — secret stays on server)
    _vactInstance ??= Vact(appId: _appId);

    // Mint a fresh one-time token from our Firebase Cloud Function
    final callable = FirebaseFunctions.instance.httpsCallable('vactToken');
    final result = await callable.call();
    final accessToken = result.data['accessToken'] as String;

    // Connect the client
    await _vactInstance!.connect(accessToken: accessToken);

    // Automatically renew the session before it expires
    _vactInstance!.sessionExpiring.listen((remaining) async {
      try {
        final r = await callable.call();
        await _vactInstance!.renew(accessToken: r.data['accessToken'] as String);
      } catch (_) {
        // Will retry on next expiring event
      }
    });

    _initialized = true;
  }

  /// Disconnect and release resources on sign-out.
  Future<void> disconnect() async {
    if (!_initialized) return;
    await _vactInstance?.dispose();
    _vactInstance = null; // ← must null this out so connect() creates a fresh instance next login
    _initialized = false;
  }
}
