# Changelog

## 2.1.0

- The heartbeat now doubles as a liveness gate. If the server reports a call is
  no longer active — the other side hung up, a backend force-terminated it, or
  the sweep reclaimed it — the SDK tears the call's media down within one
  heartbeat, automatically. Nothing in your code changes.

## 2.0.0

**The SDK no longer depends on Firebase.** `firebase_core`, `firebase_auth`
and `cloud_firestore` are gone; the only dependencies are `flutter_webrtc`
and `http`. Nothing in the public API changed, so existing call code keeps
compiling — but you can delete those three packages from your `pubspec.yaml`.

- Sessions now use an opaque `vact_st_` token instead of a Firebase custom
  token, so there is no Firebase app to initialise and no `google-services.json`.
- Signalling moved from Firestore listeners to a single long-poll on
  `/v1/events`, which carries ringing calls, the answer SDP, remote ICE
  candidates, status changes and ICE-restart negotiation.
- ICE candidates are submitted over REST and batched, so a burst of candidates
  is one request rather than a dozen document writes.

## 1.2.0

- Added `sessionExpiring`, a stream that fires five minutes before the session
  expires and again at expiry. Previously a session simply stopped working
  with nothing to tell the app.
- Added `renew(accessToken:)`, which swaps in a fresh session without
  interrupting an active call. A renewal for a different user is rejected.
- Added `VactCall.stats`, a quality sample roughly every two seconds:
  round-trip time, packet loss, jitter, bitrate, connection type and a 0-4
  `quality` score suitable for signal bars.
- Added `VactCall.setAudioRoute` for speaker/earpiece selection, which mobile
  platforms otherwise default to the earpiece even on a video call.

## 1.1.0

- Capped the time a call may spend reconnecting; billing no longer continues
  while media is unrecoverable.
- Added a request timeout (default 20s, configurable via `requestTimeout`). A
  stalled request previously hung until the OS gave up.
- `apiBaseUrl` must now use HTTPS. An access grant and a Firebase ID token
  both travel on this connection.
- Firebase is initialised before the one-time access grant is spent, so a
  configuration failure no longer burns the token.
- Call creation retries transient failures under one idempotency key instead
  of risking a duplicate ringing, billable call.
- `end()` and `cancel()` retry before tearing down locally, so a hang-up is
  not billed to the sweep deadline.
- `disconnect()` now ends active calls server-side before signing out.
- Firestore listener failures surface as a failed call instead of a silently
  stalled one.
- A second `connect()` for an App ID that is already connected is rejected
  rather than signing the first client out.

## 1.0.0

- Added one-time backend-issued access-token exchange.
- Added outgoing and incoming one-to-one audio/video calls.
- Added managed TURN configuration, Firestore signalling and heartbeats.
- Added multi-device-safe accept, decline, cancel, end and device registration.
- Established the no-App-Secret client API boundary.
