import 'package:vact_sdk/vact_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('rejects malformed public App IDs before any network call', () {
    expect(
      () => Vact(appId: 'vact_live_this_must_never_be_a_client_value'),
      throwsA(isA<VactException>()),
    );
    expect(
      () => Vact(appId: 'cp_live_this_must_never_be_a_client_value'),
      throwsA(isA<VactException>()),
    );
  });

  test('accepts vact_ App IDs and the grandfathered cp_/short forms', () {
    // The server mints vact_app_ ids; the older forms stay valid so existing
    // installations keep working after the rename.
    expect(Vact(appId: 'vact_app_${'a' * 24}').appId,
        'vact_app_${'a' * 24}');
    expect(Vact(appId: 'cp_app_${'b' * 24}').appId, 'cp_app_${'b' * 24}');
    expect(Vact(appId: 'app_${'c' * 8}').appId, 'app_${'c' * 8}');
  });

  test('connect rejects a token that is not an access grant', () async {
    final client = Vact(appId: 'vact_app_${'a' * 24}');
    // A vact_live_ App Secret must never be usable as an access token.
    await expectLater(
      client.connect(accessToken: 'vact_live_not_a_grant'),
      throwsA(isA<VactException>()),
    );
  });

  test('safe exceptions expose only code and message', () {
    const error = VactException('network_error', 'Could not reach Vact');
    expect(error.toString(), 'VactException(network_error): Could not reach Vact');
  });

  test('rejects a non-HTTPS API base URL', () {
    // An access grant and a Firebase ID token both travel on this connection.
    expect(
      () => Vact(
        appId: 'vact_app_${'a' * 24}',
        apiBaseUrl: Uri.parse('http://vact.online'),
      ),
      throwsA(isA<VactException>()
          .having((e) => e.code, 'code', 'insecure_api_base_url')),
    );
  });

  test('accepts an explicit HTTPS API base URL', () {
    expect(
      Vact(
        appId: 'vact_app_${'a' * 24}',
        apiBaseUrl: Uri.parse('https://staging.vact.online'),
      ).apiBaseUrl.scheme,
      'https',
    );
  });

  test('rejects a non-positive request timeout', () {
    expect(
      () => Vact(
        appId: 'vact_app_${'a' * 24}',
        requestTimeout: Duration.zero,
      ),
      throwsA(isA<VactException>()
          .having((e) => e.code, 'code', 'invalid_request_timeout')),
    );
  });

  test('constructing several clients for one App ID is allowed', () {
    // Hot reload rebuilds widgets constantly; only connecting is exclusive.
    final appId = 'vact_app_${'b' * 24}';
    expect(() {
      Vact(appId: appId);
      Vact(appId: appId);
    }, returnsNormally);
  });

  group('call quality score', () {
    test('a clean path scores full bars', () {
      expect(VactCall.qualityScore(const Duration(milliseconds: 40), 0.0), 4);
    });

    test('packet loss dominates the score', () {
      // 10% loss makes a call unusable no matter how fast the link is.
      expect(VactCall.qualityScore(const Duration(milliseconds: 10), 0.10), 0);
      expect(VactCall.qualityScore(const Duration(milliseconds: 10), 0.06), 2);
      expect(VactCall.qualityScore(const Duration(milliseconds: 10), 0.03), 3);
    });

    test('latency degrades the score more gently than loss', () {
      expect(VactCall.qualityScore(const Duration(milliseconds: 300), 0.0), 3);
      expect(VactCall.qualityScore(const Duration(milliseconds: 600), 0.0), 2);
    });

    test('loss and latency compound but never go below zero', () {
      expect(VactCall.qualityScore(const Duration(seconds: 2), 0.06), 0);
    });

    test('an unmeasured round trip is scored on loss alone', () {
      expect(VactCall.qualityScore(null, 0.0), 4);
      expect(VactCall.qualityScore(null, 0.03), 3);
    });
  });
}
