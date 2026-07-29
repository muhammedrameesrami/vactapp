const { VactServer } = require('@firstlogicmetalab/server-sdk');

// Replace with your actual App ID and Secret from the VACT Dashboard
const APP_ID = 'vact_app_fe30b4770cb22e7f646a459e';
const APP_SECRET = 'vact_live_62908fe303459cf5_KAcgzYQe8sk9AJZfKCXQJYr4SNHQQJLstNk2IrjJqqw';

// The URL of your deployed Firebase Function
const WEBHOOK_URL = 'https://us-central1-mitco-task.cloudfunctions.net/vactWebhook';

async function configure() {
  console.log(`Configuring webhook for ${APP_ID}...`);
  const vact = new VactServer({
    appId: APP_ID,
    appSecret: APP_SECRET,
  });

  try {
    const { signingSecret } = await vact.configureWebhook({
      url: WEBHOOK_URL,
    });
    
    console.log('\n✅ Webhook successfully configured!');
    console.log('Your VACT_WEBHOOK_SECRET is:');
    console.log('----------------------------------------------------');
    console.log(signingSecret);
    console.log('----------------------------------------------------');
    console.log('\nNext step: Run the following commands in your terminal to set it in Firebase:');
    console.log(`firebase functions:secrets:set VACT_WEBHOOK_SECRET`);
    console.log(`(Paste the secret above when prompted)`);
    console.log(`firebase deploy --only functions:vactWebhook`);
  } catch (e) {
    console.error('Failed to configure webhook:', e.message);
  }
}

configure();
