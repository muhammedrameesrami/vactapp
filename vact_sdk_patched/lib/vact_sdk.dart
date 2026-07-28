import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;

/// A safe error surfaced by the Vact API or SDK.
///
/// Credentials, SDP and ICE candidates are intentionally never included in
/// [message] or [toString].
final class VactException implements Exception {
  const VactException(this.code, this.message, {this.statusCode});

  final String code;
  final String message;
  final int? statusCode;

  @override
  String toString() => 'VactException($code): $message';
}

/// How often an active call reports liveness. The server sweeps a call only
/// after several missed beats, so a transient network failure never ends a
/// healthy call, and billing is capped at the last successful beat.
const int _heartbeatIntervalSeconds = 45;

/// How long a call may stay in [VactCallState.reconnecting] before the SDK
/// gives up and ends it. Without this cap, a device whose API connectivity
/// works but whose media never recovers would keep heartbeating — and keep
/// being billed — for a call nobody can hear.
const int _maxReconnectSeconds = 120;

/// How long each event poll waits before returning empty.
const int _eventWaitSeconds = 25;

enum VactCallType { audio, video }

enum VactCallState { ringing, connecting, connected, reconnecting, ended, failed }

/// Where call audio is played.
enum VactAudioRoute { earpiece, speaker }

/// A live quality sample for an active call.
final class VactCallStats {
  const VactCallStats({
    required this.roundTripTime,
    required this.packetsLostRatio,
    required this.jitter,
    required this.bitrateKbps,
    required this.quality,
    required this.connectionType,
  });

  /// Latency to the peer. Null until the selected pair reports one.
  final Duration? roundTripTime;

  /// Share of inbound packets lost, 0.0 to 1.0.
  final double packetsLostRatio;

  /// Inbound jitter.
  final Duration jitter;

  /// Inbound bitrate over the last sampling interval.
  final int bitrateKbps;

  /// 0 (unusable) to 4 (excellent) — suitable for signal bars.
  final int quality;

  /// `host`, `srflx` or `relay` — how media is reaching the peer.
  final String connectionType;

  @override
  String toString() => 'VactCallStats(quality: $quality, rtt: $roundTripTime, '
      'loss: ${(packetsLostRatio * 100).toStringAsFixed(1)}%, '
      '$bitrateKbps kbps, $connectionType)';
}

/// A ringing call that can be accepted or declined.
final class VactIncomingCall {
  const VactIncomingCall._({
    required this.id,
    required this.fromUserId,
    required this.callerName,
    required this.type,
    required this.expiresAt,
    required this.offer,
  });

  final String id;
  final String fromUserId;
  final String callerName;
  final VactCallType type;
  final DateTime expiresAt;

  // Signalling data is runtime-only. The SDK never logs or persists it.
  final Map<String, dynamic> offer;
}

/// An active local WebRTC call.
final class VactCall {
  VactCall._({
    required this.id,
    required this.otherUserId,
    required this.type,
    required this.isCaller,
    required this.localStream,
    required this.remoteStream,
    required RTCPeerConnection peer,
    required Future<void> Function(String action, Map<String, dynamic> body)
        action,
    required Future<void> Function() restart,
    required Future<void> Function() disposeCallback,
  })  : _peer = peer,
        _action = action,
        _restart = restart,
        _disposeCallback = disposeCallback;

  final String id;
  final String otherUserId;
  final VactCallType type;
  final bool isCaller;
  final MediaStream localStream;
  final MediaStream remoteStream;

  final RTCPeerConnection _peer;
  final Future<void> Function(String action, Map<String, dynamic> body) _action;
  final Future<void> Function() _restart;
  final Future<void> Function() _disposeCallback;
  final StreamController<VactCallState> _states =
      StreamController<VactCallState>.broadcast();
  final StreamController<VactCallStats> _stats =
      StreamController<VactCallStats>.broadcast();

  VactAudioRoute _audioRoute = VactAudioRoute.earpiece;
  Timer? _statsTimer;
  int _lastBytesReceived = 0;
  DateTime? _lastStatsAt;
  VactCallState _state = VactCallState.ringing;
  bool _closed = false;

  VactCallState get state => _state;
  Stream<VactCallState> get states => _states.stream;

  /// Periodic quality samples while connected, roughly every two seconds.
  Stream<VactCallStats> get stats => _stats.stream;

  VactAudioRoute get audioRoute => _audioRoute;

  Future<void> setMicrophoneEnabled(bool enabled) async {
    for (final track in localStream.getAudioTracks()) {
      track.enabled = enabled;
    }
  }

  Future<void> setCameraEnabled(bool enabled) async {
    for (final track in localStream.getVideoTracks()) {
      track.enabled = enabled;
    }
  }

  Future<void> switchCamera() async {
    final tracks = localStream.getVideoTracks();
    if (tracks.isNotEmpty) await Helper.switchCamera(tracks.first);
  }

  /// Plays call audio through the loudspeaker or the earpiece.
  ///
  /// Mobile operating systems default a voice call to the earpiece, which is
  /// wrong for a video call — set this when the call screen opens.
  Future<void> setAudioRoute(VactAudioRoute route) async {
    _audioRoute = route;
    await Helper.setSpeakerphoneOn(route == VactAudioRoute.speaker);
  }

  /// Requests an ICE restart after a network change.
  Future<void> restartIce() async {
    if (_closed) return;
    _setState(VactCallState.reconnecting);
    await _restart();
  }

  /// Ends an accepted call.
  ///
  /// The hang-up is retried before the local teardown, because tearing down
  /// first would stop the heartbeat while the server still believes the call
  /// is live — and the customer would be billed to the sweep deadline rather
  /// than to the moment the user pressed the button.
  Future<void> end({String reason = 'completed'}) async {
    if (_closed) return;
    try {
      await _reportTermination('end', <String, dynamic>{'endReason': reason});
    } finally {
      await _shutdown(VactCallState.ended);
    }
  }

  /// Cancels an outgoing call before it has been accepted.
  Future<void> cancel() async {
    if (_closed) return;
    try {
      await _reportTermination('cancel', const <String, dynamic>{});
    } finally {
      await _shutdown(VactCallState.ended);
    }
  }

  /// Reports a terminal action, retrying transient failures.
  ///
  /// A 4xx is terminal server-side — the call is already finished, or this
  /// session may not end it — so retrying cannot help.
  Future<void> _reportTermination(
    String action,
    Map<String, dynamic> body,
  ) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        await _action(action, body);
        return;
      } on VactException catch (error) {
        final status = error.statusCode;
        if (status != null && status >= 400 && status < 500) return;
      } catch (_) {
        // Transport failure; fall through to the retry.
      }
      if (attempt < 2) {
        await Future<void>.delayed(Duration(seconds: 1 << attempt));
      }
    }
  }

  void _setState(VactCallState value) {
    if (_closed || value == _state) return;
    _state = value;
    _states.add(value);
    if (value == VactCallState.connected) {
      _startStatsSampling();
    } else if (value == VactCallState.ended || value == VactCallState.failed) {
      _statsTimer?.cancel();
      _statsTimer = null;
    }
  }

  void _startStatsSampling() {
    if (_statsTimer != null || _stats.isClosed) return;
    _statsTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(_sampleStats().catchError((Object _) {
        // A failed sample is not worth surfacing; the next one will do.
      }));
    });
  }

  Future<void> _sampleStats() async {
    if (_closed || _stats.isClosed || !_stats.hasListener) return;
    final reports = await _peer.getStats();

    String? localId;
    String? remoteId;
    Duration? rtt;
    for (final report in reports) {
      if (report.type != 'candidate-pair') continue;
      final values = report.values;
      final selected = values['selected'] == true ||
          (values['nominated'] == true && values['state'] == 'succeeded');
      if (!selected) continue;
      localId = values['localCandidateId'] as String?;
      remoteId = values['remoteCandidateId'] as String?;
      final seconds = (values['currentRoundTripTime'] as num?)?.toDouble();
      if (seconds != null) {
        rtt = Duration(milliseconds: (seconds * 1000).round());
      }
      break;
    }

    var packetsReceived = 0;
    var packetsLost = 0;
    var jitterSeconds = 0.0;
    var bytesReceived = 0;
    for (final report in reports) {
      if (report.type != 'inbound-rtp') continue;
      final values = report.values;
      packetsReceived += ((values['packetsReceived'] as num?) ?? 0).toInt();
      packetsLost += ((values['packetsLost'] as num?) ?? 0).toInt();
      bytesReceived += ((values['bytesReceived'] as num?) ?? 0).toInt();
      final jitter = (values['jitter'] as num?)?.toDouble();
      if (jitter != null && jitter > jitterSeconds) jitterSeconds = jitter;
    }

    final sampledAt = DateTime.now();
    final elapsed = _lastStatsAt == null
        ? Duration.zero
        : sampledAt.difference(_lastStatsAt!);
    // Bitrate is a delta, so the first sample after connecting has no
    // baseline and reports zero rather than a spike.
    final bitrateKbps = elapsed.inMilliseconds > 0 && _lastBytesReceived > 0
        ? (((bytesReceived - _lastBytesReceived) * 8) / elapsed.inMilliseconds)
            .round()
        : 0;
    _lastBytesReceived = bytesReceived;
    _lastStatsAt = sampledAt;

    final total = packetsReceived + packetsLost;
    final lossRatio = total > 0 ? packetsLost / total : 0.0;

    final candidateTypes = <String>[];
    for (final report in reports) {
      if (report.id != localId && report.id != remoteId) continue;
      final candidateType = report.values['candidateType'];
      if (candidateType is String) candidateTypes.add(candidateType);
    }
    final connectionType = candidateTypes.contains('relay')
        ? 'relay'
        : candidateTypes.contains('srflx') || candidateTypes.contains('prflx')
            ? 'srflx'
            : candidateTypes.contains('host')
                ? 'host'
                : 'unknown';

    _stats.add(VactCallStats(
      roundTripTime: rtt,
      packetsLostRatio: lossRatio,
      jitter: Duration(milliseconds: (jitterSeconds * 1000).round()),
      bitrateKbps: bitrateKbps < 0 ? 0 : bitrateKbps,
      quality: qualityScore(rtt, lossRatio),
      connectionType: connectionType,
    ));
  }

  /// Collapses latency and loss into 0-4 bars.
  ///
  /// Loss hurts a call more than latency does, so it dominates the score:
  /// 300ms of delay is tolerable, 10% packet loss is not.
  @visibleForTesting
  static int qualityScore(Duration? rtt, double lossRatio) {
    if (lossRatio >= 0.10) return 0;
    var score = 4;
    if (lossRatio >= 0.05) {
      score -= 2;
    } else if (lossRatio >= 0.02) {
      score -= 1;
    }
    final ms = rtt?.inMilliseconds;
    if (ms != null) {
      if (ms >= 500) {
        score -= 2;
      } else if (ms >= 250) {
        score -= 1;
      }
    }
    return score.clamp(0, 4);
  }

  Future<void> _shutdown(VactCallState terminalState) async {
    if (_closed) return;
    _state = terminalState;
    if (!_states.isClosed) _states.add(terminalState);
    _closed = true;
    // This assigns _state directly rather than going through _setState, so
    // the sampling timer has to be stopped here too or it outlives the call.
    _statsTimer?.cancel();
    _statsTimer = null;
    await _disposeCallback();
    for (final track in localStream.getTracks()) {
      await track.stop();
    }
    await localStream.dispose();
    await remoteStream.dispose();
    await _peer.close();
    await _states.close();
    await _stats.close();
  }
}

/// Vact's intentionally small public API.
///
/// The only dependencies are an HTTP client and WebRTC: signalling is plain
/// JSON over HTTPS, so an integrating app needs no Firebase, no realtime
/// database and no vendor account of any kind.
///
/// The App ID is public. [connect] accepts only a short-lived, one-time access
/// token created by the customer's backend. There is deliberately no API that
/// accepts an App Secret, which prevents accidentally shipping the secret in a
/// Flutter, Android, iOS, web or desktop build.
final class Vact {
  Vact({
    required this.appId,
    Uri? apiBaseUrl,
    http.Client? httpClient,
    Duration requestTimeout = const Duration(seconds: 20),
  })  : apiBaseUrl = apiBaseUrl ?? Uri.parse('https://vact.online'),
        _http = httpClient ?? http.Client(),
        _ownsHttp = httpClient == null,
        _requestTimeout = requestTimeout {
    // vact_app_ is the current form; cp_app_ and the short app_ form remain
    // valid so existing installations keep working.
    if (!RegExp(r'^(vact_app_[a-f0-9]{24}|cp_app_[a-f0-9]{24}|app_[a-f0-9]{8})$')
        .hasMatch(appId)) {
      throw const VactException('invalid_app_id', 'Invalid Vact App ID');
    }
    // An access token and a session token both travel on this connection.
    if (this.apiBaseUrl.scheme != 'https') {
      throw const VactException(
        'insecure_api_base_url',
        'apiBaseUrl must use https',
      );
    }
    if (requestTimeout <= Duration.zero) {
      throw const VactException(
        'invalid_request_timeout',
        'requestTimeout must be positive',
      );
    }
  }

  static const sdkVersion = '2.1.0';

  final String appId;
  final Uri apiBaseUrl;
  final http.Client _http;
  final bool _ownsHttp;
  final Duration _requestTimeout;

  String? _sessionToken;
  String? _userId;
  DateTime? _sessionExpiresAt;
  bool _disposed = false;
  bool _listening = false;
  int _cursor = 0;

  final Map<String, _ActiveCall> _calls = <String, _ActiveCall>{};
  final StreamController<List<VactIncomingCall>> _incoming =
      StreamController<List<VactIncomingCall>>.broadcast();
  final Map<String, VactIncomingCall> _ringing = <String, VactIncomingCall>{};
  final StreamController<Duration> _sessionExpiring =
      StreamController<Duration>.broadcast();
  Timer? _expiryTimer;
  Timer? _expiredTimer;

  bool get isConnected =>
      !_disposed &&
      _sessionToken != null &&
      _sessionExpiresAt?.isAfter(DateTime.now().toUtc()) == true;

  String get userId {
    _ensureConnected();
    return _userId!;
  }

  DateTime get sessionExpiresAt {
    _ensureConnected();
    return _sessionExpiresAt!;
  }

  /// Fires shortly before the session expires, then again when it has.
  ///
  /// Listen here and call [renew] with a freshly minted access token.
  Stream<Duration> get sessionExpiring => _sessionExpiring.stream;

  /// How far ahead of expiry the first warning fires.
  static const Duration expiryWarningLead = Duration(minutes: 5);

  /// Exchanges a one-time access token minted by the customer's backend.
  Future<void> connect({required String accessToken}) =>
      _openSession(accessToken: accessToken, renewal: false);

  /// Replaces the current session with a fresh one, in place.
  ///
  /// Active calls are unaffected — the session token is swapped and the event
  /// feed resumes from the same cursor.
  Future<void> renew({required String accessToken}) =>
      _openSession(accessToken: accessToken, renewal: true);

  Future<void> _openSession({
    required String accessToken,
    required bool renewal,
  }) async {
    _ensureNotDisposed();
    // VACT mints vact_at_ tokens; cp_at_ is the previous brand and stays
    // valid so tokens issued before the rename still connect.
    if (!accessToken.startsWith('vact_at_') &&
        !accessToken.startsWith('cp_at_')) {
      throw const VactException(
        'invalid_access_token',
        'The access token is malformed',
      );
    }

    final exchange = await _request(
      'POST',
      '/v1/session/exchange',
      body: <String, dynamic>{'appId': appId, 'accessToken': accessToken},
    );
    if (_string(exchange, 'appId') != appId) {
      throw const VactException(
        'app_mismatch',
        'The access token belongs to another application',
      );
    }
    final nextUserId = _string(exchange, 'userId');
    // A renewal that arrives for a different user would silently break every
    // active call, because they belong to the original identity.
    if (renewal && _userId != null && nextUserId != _userId) {
      throw const VactException(
        'identity_changed',
        'The renewal token belongs to a different user',
      );
    }

    _sessionToken = _string(exchange, 'sessionToken');
    _userId = nextUserId;
    _sessionExpiresAt =
        DateTime.parse(_string(exchange, 'sessionExpiresAt')).toUtc();
    _scheduleExpiryWarning();
    if (!_listening) unawaited(_listen());
  }

  void _scheduleExpiryWarning() {
    _expiryTimer?.cancel();
    _expiredTimer?.cancel();
    final expiresAt = _sessionExpiresAt;
    if (expiresAt == null) return;

    final untilExpiry = expiresAt.difference(DateTime.now().toUtc());
    final untilWarning = untilExpiry - expiryWarningLead;
    void emit(Duration remaining) {
      if (!_sessionExpiring.isClosed) _sessionExpiring.add(remaining);
    }

    // A session shorter than the lead time still deserves one warning.
    if (untilWarning.isNegative) {
      if (!untilExpiry.isNegative) emit(untilExpiry);
    } else {
      _expiryTimer = Timer(untilWarning, () => emit(expiryWarningLead));
    }
    if (!untilExpiry.isNegative) {
      _expiredTimer = Timer(untilExpiry, () => emit(Duration.zero));
    }
  }

  /// The single long-poll loop that drives everything inbound.
  ///
  /// One request carries ringing calls, the answer SDP, remote candidates,
  /// status changes and ICE-restart negotiation. It returns as soon as
  /// anything happens, so ringing is immediate.
  Future<void> _listen() async {
    _listening = true;
    while (!_disposed && _sessionToken != null) {
      try {
        final batch = await _request(
          'GET',
          '/v1/events?cursor=$_cursor&wait=$_eventWaitSeconds',
          timeout: Duration(seconds: _eventWaitSeconds + 15),
        );
        _cursor = (batch['cursor'] as num?)?.toInt() ?? _cursor;
        final list = batch['events'];
        if (list is List) {
          for (final raw in list) {
            if (raw is Map) {
              await _handleEvent(Map<String, dynamic>.from(raw));
            }
          }
        }
      } on VactException catch (error) {
        if (error.code == 'expired_session' || error.code == 'invalid_session') {
          _listening = false;
          return;
        }
        await Future<void>.delayed(const Duration(seconds: 2));
      } catch (_) {
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
    _listening = false;
  }

  Future<void> _handleEvent(Map<String, dynamic> event) async {
    final type = event['type'] as String?;
    final callId = event['callId'] as String?;
    if (callId == null) return;
    final active = _calls[callId];

    switch (type) {
      case 'incoming_call':
        final offer = event['offer'];
        print('DEBUG: incoming.offer = $offer');
        if (offer is! Map) return;
        _ringing[callId] = VactIncomingCall._(
          id: callId,
          fromUserId: event['fromUserId'] as String? ?? '',
          callerName: event['callerName'] as String? ?? 'Unknown caller',
          type: event['callType'] == 'video'
              ? VactCallType.video
              : VactCallType.audio,
          expiresAt: _date(event['expiresAt']) ??
              DateTime.now().toUtc().add(const Duration(seconds: 45)),
          offer: Map<String, dynamic>.from(offer),
        );
        _publishRinging();
        break;

      case 'call_answered':
        final answer = event['answer'];
        if (active == null || answer is! Map) return;
        await active.applyAnswer(Map<String, dynamic>.from(answer));
        break;

      case 'ice_candidate':
        final candidate = event['candidate'];
        if (active == null || candidate is! Map) return;
        await active.addRemoteCandidate(Map<String, dynamic>.from(candidate));
        break;

      case 'call_connected':
        active?.call._setState(VactCallState.connected);
        break;

      case 'call_ended':
        _ringing.remove(callId);
        _publishRinging();
        await active?.call._shutdown(VactCallState.ended);
        break;

      case 'restart_offer':
      case 'restart_answer':
      case 'restart_request':
        await active?.handleRestart(type!, event);
        break;
    }
  }

  void _publishRinging() {
    if (_incoming.isClosed) return;
    final now = DateTime.now().toUtc();
    _ringing.removeWhere((_, call) => !call.expiresAt.isAfter(now));
    _incoming.add(List<VactIncomingCall>.unmodifiable(_ringing.values));
  }

  /// A live list of ringing calls for this authenticated user.
  Stream<List<VactIncomingCall>> incomingCalls() {
    _ensureConnected();
    return _incoming.stream;
  }

  /// Starts an outgoing audio or video call.
  Future<VactCall> call(
    String toUserId, {
    bool video = false,
    String? callerName,
    Map<String, dynamic>? mediaConstraints,
  }) async {
    _ensureConnected();
    _validateUserId(toUserId);
    final media = await navigator.mediaDevices.getUserMedia(
      mediaConstraints ?? _defaultMediaConstraints(video),
    );
    _PreparedPeer? prepared;
    try {
      prepared = await _preparePeer(media);
      final offer = await prepared.peer.createOffer(<String, dynamic>{});
      await prepared.peer.setLocalDescription(offer);

      // One key for every attempt. A create request that times out may still
      // have reached the server, so blind retries could ring the callee twice
      // and open two billable calls; replaying the same key returns the
      // original call instead.
      final idempotencyKey = _randomRequestId();
      final body = <String, dynamic>{
        'toUserId': toUserId,
        'callType': video ? 'video' : 'audio',
        'callerName': callerName,
        'offer': <String, dynamic>{'type': offer.type, 'sdp': offer.sdp},
      }..removeWhere((_, value) => value == null);
      Map<String, dynamic>? created;
      for (var attempt = 0; attempt < 3 && created == null; attempt++) {
        try {
          created = await _request(
            'POST',
            '/v1/calls',
            body: body,
            headers: <String, String>{'Idempotency-Key': idempotencyKey},
          );
        } on VactException catch (error) {
          // A rejection (no credit, blocked callee, bad offer) will be
          // rejected identically next time, so surface it now.
          final status = error.statusCode;
          if (status != null && status >= 400 && status < 500) rethrow;
          if (attempt == 2) rethrow;
          await Future<void>.delayed(Duration(seconds: 1 << attempt));
        }
      }
      return _activateCall(
        callId: _string(created!, 'callId'),
        otherUserId: toUserId,
        type: video ? VactCallType.video : VactCallType.audio,
        isCaller: true,
        prepared: prepared,
        startedAt: _date(created['createdAt']) ?? DateTime.now().toUtc(),
      );
    } catch (_) {
      await _discard(prepared, media);
      rethrow;
    }
  }

  /// Accepts a ringing call. The server transaction guarantees that only one
  /// device can win when the same user is signed in on multiple devices.
  Future<VactCall> accept(
    VactIncomingCall incoming, {
    String? calleeName,
    String? deviceId,
    Map<String, dynamic>? mediaConstraints,
  }) async {
    _ensureConnected();
    final video = incoming.type == VactCallType.video;
    final media = await navigator.mediaDevices.getUserMedia(
      mediaConstraints ?? _defaultMediaConstraints(video),
    );
    _PreparedPeer? prepared;
    try {
      prepared = await _preparePeer(media);
      final sdp = incoming.offer['sdp'] as String?;
      final type = incoming.offer['type'] as String?;
      print('DEBUG accept: sdp length=${sdp?.length}, type=$type');
      await prepared.peer.setRemoteDescription(RTCSessionDescription(
        _normalizeSdp(sdp),
        type,
      ));
      final answer = await prepared.peer.createAnswer(<String, dynamic>{});
      await prepared.peer.setLocalDescription(answer);
      await _request(
        'POST',
        '/v1/calls/${Uri.encodeComponent(incoming.id)}/accept',
        body: <String, dynamic>{
          'answer': <String, dynamic>{'type': answer.type, 'sdp': answer.sdp},
          'calleeName': calleeName,
          'deviceId': deviceId,
        }..removeWhere((_, value) => value == null),
      );
      _ringing.remove(incoming.id);
      _publishRinging();
      final call = _activateCall(
        callId: incoming.id,
        otherUserId: incoming.fromUserId,
        type: incoming.type,
        isCaller: false,
        prepared: prepared,
        startedAt: DateTime.now().toUtc(),
      );
      // The offer was applied above, so remote candidates can flow at once.
      _calls[incoming.id]?.remoteReady = true;
      await _calls[incoming.id]?.flushPendingCandidates();
      return call;
    } catch (_) {
      await _discard(prepared, media);
      rethrow;
    }
  }

  Future<void> decline(VactIncomingCall incoming) async {
    _ensureConnected();
    _ringing.remove(incoming.id);
    _publishRinging();
    await _request(
      'POST',
      '/v1/calls/${Uri.encodeComponent(incoming.id)}/decline',
      body: const <String, dynamic>{},
    );
  }

  /// Advanced: registers a token issued by the Vact push sender.
  /// Most customer apps should use signed webhooks and send push notifications
  /// from their own backend instead.
  Future<void> registerDevice({
    required String deviceId,
    required String fcmToken,
    required String platform,
  }) async {
    _ensureConnected();
    if (!RegExp(r'^[A-Za-z0-9_.-]{1,128}$').hasMatch(deviceId)) {
      throw const VactException('invalid_device_id', 'Invalid device ID');
    }
    await _request(
      'PUT',
      '/v1/devices/${Uri.encodeComponent(deviceId)}',
      body: <String, dynamic>{'fcmToken': fcmToken, 'platform': platform},
    );
  }

  Future<void> unregisterDevice(String deviceId) async {
    _ensureConnected();
    await _request(
      'DELETE',
      '/v1/devices/${Uri.encodeComponent(deviceId)}',
    );
  }

  /// Ends any active call on the server, then drops the session.
  ///
  /// Tearing down locally without telling the server would leave the call
  /// billing until the heartbeat grace period expired.
  Future<void> disconnect() async {
    for (final active in _calls.values.toList(growable: false)) {
      try {
        await active.call.end(reason: 'disconnected');
      } catch (_) {
        await active.call._shutdown(VactCallState.ended);
      }
    }
    _expiryTimer?.cancel();
    _expiredTimer?.cancel();
    _expiryTimer = null;
    _expiredTimer = null;
    _sessionToken = null;
    _userId = null;
    _sessionExpiresAt = null;
    _ringing.clear();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    await disconnect();
    _disposed = true;
    await _incoming.close();
    await _sessionExpiring.close();
    if (_ownsHttp) _http.close();
  }

  Future<void> _discard(_PreparedPeer? prepared, MediaStream media) async {
    if (prepared != null) {
      await prepared.peer.close();
      await prepared.remoteStream.dispose();
    }
    for (final track in media.getTracks()) {
      await track.stop();
    }
    await media.dispose();
  }

  Future<_PreparedPeer> _preparePeer(MediaStream localStream) async {
    final rtc = await _request('GET', '/v1/rtc/config');
    var iceServers = rtc['iceServers'];
    if (iceServers is Map) {
      iceServers = [iceServers];
    }
    if (iceServers is! List) {
      throw const VactException(
        'invalid_rtc_config',
        'RTC configuration is unavailable',
      );
    }
    final peer = await createPeerConnection(<String, dynamic>{
      'iceServers': iceServers,
      'iceCandidatePoolSize': 2,
    });
    for (final track in localStream.getTracks()) {
      await peer.addTrack(track, localStream);
    }
    final remoteStream = await createLocalMediaStream('vact_remote');
    peer.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        for (final track in event.streams.first.getTracks()) {
          if (remoteStream.getTracks().every((current) => current.id != track.id)) {
            unawaited(remoteStream.addTrack(track));
          }
        }
      } else {
        unawaited(remoteStream.addTrack(event.track));
      }
    };
    final earlyCandidates = <RTCIceCandidate>[];
    peer.onIceCandidate = earlyCandidates.add;
    return _PreparedPeer(peer, localStream, remoteStream, earlyCandidates);
  }

  VactCall _activateCall({
    required String callId,
    required String otherUserId,
    required VactCallType type,
    required bool isCaller,
    required _PreparedPeer prepared,
    required DateTime startedAt,
  }) {
    late _ActiveCall active;

    final call = VactCall._(
      id: callId,
      otherUserId: otherUserId,
      type: type,
      isCaller: isCaller,
      localStream: prepared.localStream,
      remoteStream: prepared.remoteStream,
      peer: prepared.peer,
      action: (action, body) => _request(
        'POST',
        '/v1/calls/${Uri.encodeComponent(callId)}/$action',
        body: body,
      ).then((_) {}),
      restart: () => active.requestRestart(),
      disposeCallback: () async {
        active.dispose();
        _calls.remove(callId);
      },
    );

    active = _ActiveCall(
      call: call,
      peer: prepared.peer,
      isCaller: isCaller,
      startedAt: startedAt,
      send: (path, body) => _request('POST', path, body: body),
      submitCandidates: (candidates) => _request(
        'POST',
        '/v1/calls/${Uri.encodeComponent(callId)}/candidates',
        body: <String, dynamic>{'candidates': candidates},
      ),
    );
    _calls[callId] = active;
    active.start(prepared.earlyCandidates);
    prepared.earlyCandidates.clear();
    return call;
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? headers,
    Duration? timeout,
  }) async {
    _ensureNotDisposed();
    final uri = apiBaseUrl.resolve(path);
    final requestHeaders = <String, String>{
      'Accept': 'application/json',
      if (body != null) 'Content-Type': 'application/json',
      if (_sessionToken != null) 'Authorization': 'Bearer $_sessionToken',
      ...?headers,
    };
    late http.Response response;
    try {
      final encodedBody = body == null ? null : jsonEncode(body);
      // Without an explicit deadline a stalled connection hangs until the OS
      // gives up, which on mobile can be minutes.
      response = await switch (method) {
        'GET' => _http.get(uri, headers: requestHeaders),
        'POST' => _http.post(uri, headers: requestHeaders, body: encodedBody),
        'PUT' => _http.put(uri, headers: requestHeaders, body: encodedBody),
        'DELETE' => _http.delete(uri, headers: requestHeaders),
        _ => throw StateError('Unsupported HTTP method'),
      }
          .timeout(timeout ?? _requestTimeout);
    } on TimeoutException {
      throw const VactException('timeout', 'Vact did not respond');
    } catch (error) {
      if (error is VactException) rethrow;
      throw const VactException('network_error', 'Could not reach Vact');
    }
    final dynamic decoded;
    try {
      decoded = response.body.isEmpty ? <String, dynamic>{} : jsonDecode(response.body);
    } catch (_) {
      throw VactException(
        'invalid_response',
        'Vact returned an invalid response',
        statusCode: response.statusCode,
      );
    }
    final payload = decoded is Map
        ? Map<String, dynamic>.from(decoded)
        : <String, dynamic>{};
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final error = payload['error'];
      final errorMap = error is Map ? Map<String, dynamic>.from(error) : payload;
      throw VactException(
        errorMap['code'] as String? ?? 'request_failed',
        errorMap['message'] as String? ?? 'Vact request failed',
        statusCode: response.statusCode,
      );
    }
    return payload;
  }

  void _ensureNotDisposed() {
    if (_disposed) {
      throw const VactException('disposed', 'Vact has been disposed');
    }
  }

  void _ensureConnected() {
    _ensureNotDisposed();
    if (!isConnected) {
      throw const VactException(
        'not_connected',
        'Call connect() with a fresh access token first',
      );
    }
  }

  static String _string(Map<String, dynamic> value, String key) {
    final result = value[key];
    if (result is String && result.isNotEmpty) return result;
    throw const VactException('invalid_response', 'Vact response is incomplete');
  }

  static DateTime? _date(dynamic value) {
    if (value is String && value.isNotEmpty) {
      return DateTime.tryParse(value)?.toUtc();
    }
    return null;
  }

  static void _validateUserId(String value) {
    if (!RegExp(r'^[A-Za-z0-9_.-]{1,64}$').hasMatch(value)) {
      throw const VactException('invalid_user_id', 'Invalid user ID');
    }
  }

  static String _randomRequestId() {
    final random = Random.secure();
    final bytes = List<int>.generate(18, (_) => random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  static Map<String, dynamic> _defaultMediaConstraints(bool video) =>
      <String, dynamic>{
        'audio': <String, dynamic>{
          'echoCancellation': true,
          'noiseSuppression': true,
          'autoGainControl': true,
        },
        'video': video
            ? <String, dynamic>{
                'facingMode': 'user',
                'width': <String, int>{'ideal': 1280},
                'height': <String, int>{'ideal': 720},
              }
            : false,
      };
}

/// Per-call machinery: candidate batching, restart negotiation, heartbeat.
final class _ActiveCall {
  _ActiveCall({
    required this.call,
    required this.peer,
    required this.isCaller,
    required this.startedAt,
    required this.send,
    required this.submitCandidates,
  });

  final VactCall call;
  final RTCPeerConnection peer;
  final bool isCaller;
  final DateTime startedAt;
  final Future<Map<String, dynamic>> Function(String path, Map<String, dynamic> body) send;
  final Future<Map<String, dynamic>> Function(List<Map<String, dynamic>> candidates)
      submitCandidates;

  final List<Map<String, dynamic>> _pending = <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> _pendingRemote = <Map<String, dynamic>>[];
  Timer? _flushTimer;
  Timer? _heartbeat;
  Timer? _reconnectTimer;
  DateTime? _reconnectingSince;
  bool remoteReady = false;
  bool _connectedReported = false;
  int _restartSequence = 0;
  int _lastRestartApplied = 0;
  int _sent = 0;

  void start(List<RTCIceCandidate> early) {
    for (final candidate in early) {
      _queueLocal(candidate);
    }
    peer.onIceCandidate = _queueLocal;
    peer.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _reconnectTimer?.cancel();
        _reconnectTimer = null;
        _reconnectingSince = null;
        call._setState(VactCallState.connected);
        _startHeartbeat();
        _reportConnected();
      } else if (state ==
          RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        call._setState(VactCallState.reconnecting);
        _reconnectingSince ??= DateTime.now();
        _reconnectTimer ??= Timer(const Duration(seconds: 3), () {
          unawaited(call.restartIce().catchError((Object _) {}));
        });
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        call._setState(VactCallState.failed);
        _reconnectingSince ??= DateTime.now();
        unawaited(call.restartIce().catchError((Object _) {}));
      }
    };
  }

  /// Batches candidates so a burst becomes one request instead of a dozen.
  void _queueLocal(RTCIceCandidate candidate) {
    if (candidate.candidate == null || candidate.candidate!.isEmpty) return;
    if (_sent >= 128) return;
    _pending.add(<String, dynamic>{
      'candidate': candidate.candidate,
      if (candidate.sdpMid != null) 'sdpMid': candidate.sdpMid,
      if (candidate.sdpMLineIndex != null)
        'sdpMLineIndex': candidate.sdpMLineIndex,
    });
    _flushTimer?.cancel();
    _flushTimer = Timer(const Duration(milliseconds: 50), () {
      unawaited(_flushLocal());
    });
  }

  Future<void> _flushLocal() async {
    if (_pending.isEmpty) return;
    final batch = _pending.take(32).toList(growable: false);
    _pending.removeRange(0, batch.length);
    _sent += batch.length;
    try {
      await submitCandidates(batch);
    } catch (_) {
      // Connectivity problems surface through the WebRTC state machine.
    }
  }

  Future<void> addRemoteCandidate(Map<String, dynamic> candidate) async {
    if (!remoteReady) {
      _pendingRemote.add(candidate);
      return;
    }
    await peer.addCandidate(RTCIceCandidate(
      candidate['candidate'] as String?,
      candidate['sdpMid'] as String?,
      (candidate['sdpMLineIndex'] as num?)?.toInt(),
    ));
  }

  Future<void> flushPendingCandidates() async {
    while (_pendingRemote.isNotEmpty) {
      final candidate = _pendingRemote.removeAt(0);
      try {
        await peer.addCandidate(RTCIceCandidate(
          candidate['candidate'] as String?,
          candidate['sdpMid'] as String?,
          (candidate['sdpMLineIndex'] as num?)?.toInt(),
        ));
      } catch (_) {
        // A stale candidate after a restart is not fatal.
      }
    }
  }

  Future<void> applyAnswer(Map<String, dynamic> answer) async {
    if (remoteReady) return;
    await peer.setRemoteDescription(RTCSessionDescription(
      _normalizeSdp(answer['sdp'] as String?),
      answer['type'] as String?,
    ));
    remoteReady = true;
    call._setState(VactCallState.connecting);
    await flushPendingCandidates();
  }

  /// The caller always stays the offerer, which removes glare entirely.
  Future<void> requestRestart() async {
    final sequence = ++_restartSequence;
    if (!isCaller) {
      await send('/v1/calls/${Uri.encodeComponent(call.id)}/restart',
          <String, dynamic>{'n': sequence});
      return;
    }
    final offer = await peer.createOffer(<String, dynamic>{'iceRestart': true});
    await peer.setLocalDescription(offer);
    await send('/v1/calls/${Uri.encodeComponent(call.id)}/restart',
        <String, dynamic>{
          'offer': <String, dynamic>{'type': offer.type, 'sdp': offer.sdp},
          'n': sequence,
        });
  }

  Future<void> handleRestart(String type, Map<String, dynamic> event) async {
    if (type == 'restart_request' && isCaller) {
      await requestRestart();
      return;
    }
    final payload = event[type == 'restart_offer' ? 'restartOffer' : 'restartAnswer'];
    if (payload is! Map) return;
    final data = Map<String, dynamic>.from(payload);
    final sequence = (data['n'] as num?)?.toInt() ?? 0;
    if (sequence <= _lastRestartApplied) return;
    _lastRestartApplied = sequence;

    if (type == 'restart_offer' && !isCaller) {
      call._setState(VactCallState.reconnecting);
      await peer.setRemoteDescription(RTCSessionDescription(
        _normalizeSdp(data['sdp'] as String?), data['type'] as String?));
      final answer = await peer.createAnswer(<String, dynamic>{});
      await peer.setLocalDescription(answer);
      await send('/v1/calls/${Uri.encodeComponent(call.id)}/restart',
          <String, dynamic>{
            'answer': <String, dynamic>{'type': answer.type, 'sdp': answer.sdp},
            'n': sequence,
          });
    } else if (type == 'restart_answer' && isCaller) {
      await peer.setRemoteDescription(RTCSessionDescription(
        _normalizeSdp(data['sdp'] as String?), data['type'] as String?));
    }
  }

  void _startHeartbeat() {
    _heartbeat ??= Timer.periodic(
      const Duration(seconds: _heartbeatIntervalSeconds),
      (_) {
        // A call whose media never recovers must not keep billing.
        if (call.state == VactCallState.reconnecting) {
          final since = _reconnectingSince ??= DateTime.now();
          if (DateTime.now().difference(since).inSeconds >= _maxReconnectSeconds) {
            unawaited(call.end(reason: 'media_lost').catchError((Object _) {}));
            return;
          }
        }
        unawaited(_beat());
      },
    );
  }

  Future<void> _beat() async {
    for (var attempt = 0; attempt < 2; attempt++) {
      if (call.state == VactCallState.ended ||
          call.state == VactCallState.failed) {
        return;
      }
      try {
        await send('/v1/calls/${Uri.encodeComponent(call.id)}/heartbeat',
            const <String, dynamic>{});
        return;
      } on VactException catch (error) {
        // The heartbeat doubles as a liveness gate. If the server reports the
        // call is no longer active — a hang-up elsewhere, a backend terminate,
        // or the sweep — tear the media down here rather than leaving it up.
        // This is what makes a server-side termination actually stop the call.
        if (error.code == 'call_not_active' || error.code == 'call_not_found') {
          unawaited(call._shutdown(VactCallState.ended));
          return;
        }
        // Any other 4xx is terminal server-side; retrying cannot help.
        final status = error.statusCode;
        if (status != null && status >= 400 && status < 500) return;
      } catch (_) {
        // Transport failure — fall through to the retry.
      }
      if (attempt == 0) {
        await Future<void>.delayed(const Duration(seconds: 3));
      }
    }
  }

  void _reportConnected() {
    if (_connectedReported) return;
    _connectedReported = true;
    unawaited(send('/v1/calls/${Uri.encodeComponent(call.id)}/connected',
        const <String, dynamic>{}).catchError((Object _) {
      _connectedReported = false; // the heartbeat will try again
      return <String, dynamic>{};
    }));
  }

  void dispose() {
    _flushTimer?.cancel();
    _heartbeat?.cancel();
    _reconnectTimer?.cancel();
  }
}

final class _PreparedPeer {
  const _PreparedPeer(
    this.peer,
    this.localStream,
    this.remoteStream,
    this.earlyCandidates,
  );

  final RTCPeerConnection peer;
  final MediaStream localStream;
  final MediaStream remoteStream;
  final List<RTCIceCandidate> earlyCandidates;
}

String? _normalizeSdp(String? sdp) {
  if (sdp == null) return null;
  final lines = sdp.split(RegExp(r'\r?\n'));
  final validLines = <String>[];
  for (var line in lines) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    if (trimmed.startsWith('a=rtpmap:')) {
      final content = trimmed.substring('a=rtpmap:'.length).trim();
      final spaceIndex = content.indexOf(' ');
      if (spaceIndex == -1 || !content.substring(spaceIndex).contains('/')) {
        print('VACT SDK: Filtering out malformed SDP line: "$trimmed"');
        continue;
      }
    }
    validLines.add(trimmed);
  }
  return validLines.join('\r\n') + '\r\n';
}

