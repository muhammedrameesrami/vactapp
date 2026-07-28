# VACT Flutter SDK

Secure one-to-one voice and video calling with a deliberately small public API.

## Security boundary

- Put only the public `cp_app_...` App ID in the Flutter app.
- Keep the `cp_live_...` App Secret in your backend secret manager.
- Your backend authenticates its own user, chooses the `userId`, and requests a
  five-minute, one-time VACT access token.
- Give that access token to the Flutter app and call `connect` immediately.
- The package contains no customer data, App Secrets, TURN provider token, or
  private Firebase credential. It also does not log tokens, SDP, or candidates.

Public infrastructure identifiers and the API hostname are not credentials.
Firestore access still requires a valid VACT session and is restricted by
server-owned security rules.

## Flutter integration

```yaml
dependencies:
  vact_sdk:
    path: ../vact_sdk
```

```dart
import 'package:vact_sdk/vact_sdk.dart';

final vact = Vact(appId: 'vact_app_your_public_app_id');

// Fetch this one-time token from YOUR authenticated backend.
await vact.connect(accessToken: accessTokenFromYourBackend);

final call = await vact.call('user_42', video: true);
call.states.listen((state) => print(state)); // Do not print credentials.
```

The SDK automatically requests an ICE restart after an ordinary network
disconnect. Applications can also call `call.restartIce()` after observing a
platform network change; the caller remains the offerer to avoid glare.

Receive and answer calls:

```dart
vact.incomingCalls().listen((calls) async {
  if (calls.isEmpty) return;
  final activeCall = await vact.accept(
    calls.first,
    deviceId: installationId,
  );
  // Bind activeCall.localStream and activeCall.remoteStream to RTCVideoView.
});
```

The host application remains responsible for camera/microphone permission UI,
FCM/APNs setup, Android foreground/full-screen call presentation, and iOS
PushKit/CallKit integration.

## Backend token endpoint

This example runs only on your server:

```js
app.post('/api/callerpro-token', requireYourLogin, async (req, res) => {
  const userId = req.user.id; // Never trust a userId supplied by the client.
  const response = await fetch(
    `https://vact.online/v1/apps/${process.env.VACT_APP_ID}/tokens`,
    {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${process.env.VACT_APP_SECRET}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        userId,
        permissions: [
          'call:create', 'call:receive', 'call:accept', 'call:end',
          'telemetry:write',
        ],
        sessionTtlSeconds: 3600,
      }),
    },
  );
  const payload = await response.json();
  res.status(response.status).json(response.ok
    ? { accessToken: payload.accessToken, expiresAt: payload.tokenExpiresAt }
    : { error: 'calling_unavailable' });
});
```

Do not proxy the App Secret to the client, include it in remote configuration,
or place it in a mobile/web environment variable. Client-side environment
variables are recoverable from built applications.

For background calls, configure VACT's signed webhook with the server SDK.
Your backend verifies the raw request, deduplicates `eventId`, and sends FCM,
APNs or PushKit using your own notification project. Customer push credentials
do not belong in this Flutter package.
