/**
 * VactOnline Cloud Function — mints a short-lived VACT access token.
 *
 * The App Secret NEVER leaves Google Cloud.
 * It is stored in Firebase Secret Manager:
 *   firebase functions:secrets:set VACT_APP_SECRET
 *
 * Then deploy:
 *   firebase deploy --only functions:vactToken
 */

const { onCall, HttpsError } = require('firebase-functions/v2/https');
const { defineSecret } = require('firebase-functions/params');

const APP_SECRET = defineSecret('VACT_APP_SECRET');

// Replace with your public App ID from https://vact.online dashboard
const APP_ID = 'vact_app_fe30b4770cb22e7f646a459e';

exports.vactToken = onCall({ secrets: [APP_SECRET] }, async (request) => {
  // Firebase has already verified this identity — the client cannot forge it.
  if (!request.auth) {
    throw new HttpsError('unauthenticated', 'You must be signed in to make calls.');
  }

  const userId = request.auth.uid;

  const response = await fetch(
    `https://vact.online/v1/apps/${APP_ID}/tokens`,
    {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${APP_SECRET.value()}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        userId,
        permissions: [
          'call:create',
          'call:receive',
          'call:accept',
          'call:end',
          'telemetry:write',
        ],
        sessionTtlSeconds: 3600,
      }),
    }
  );
 console.log('111111111111111111111111111111111111');
  console.log(response);
  console.log('00000000000000000000000000000000000000');
  

  if (!response.ok) {
    const err = await response.json().catch(() => ({}));
    console.error('VACT token error:', response.status, err);
    throw new HttpsError('unavailable', 'calling_unavailable');
  }

  const token = await response.json();
  return {
    accessToken: token.accessToken,
    expiresAt: token.tokenExpiresAt,
  };
});
