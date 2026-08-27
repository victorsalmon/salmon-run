import { sendEmail } from '../lib/smtp.mjs';

function parseArgs() {
  const args = {};
  for (let i = 2; i < process.argv.length; i++) {
    const arg = process.argv[i];
    if (arg.startsWith('--')) {
      const eqIdx = arg.indexOf('=');
      if (eqIdx !== -1) {
        args[arg.slice(2, eqIdx)] = arg.slice(eqIdx + 1);
      } else {
        const val = process.argv[i + 1];
        if (val && !val.startsWith('--')) {
          args[arg.slice(2)] = val;
          i++;
        } else {
          args[arg.slice(2)] = true;
        }
      }
    }
  }
  return args;
}

function buildTransportConfig(args) {
  return {
    host: args.host || process.env.SMTP_HOST || '',
    port: parseInt(args.port || process.env.SMTP_PORT || '465', 10),
    secure: args.secure !== 'false',
    user: args.user || process.env.SMTP_USER || '',
    password: args.pass || process.env.SMTP_PASS || '',
    from: args.from || process.env.SMTP_FROM || '',
  };
}

function buildMessage(args) {
  const attachments = [];
  if (args.attach) {
    const files = Array.isArray(args.attach) ? args.attach : [args.attach];
    for (const f of files) {
      attachments.push(f);
    }
  }
  return {
    to: args.to || '',
    subject: args.subject || '',
    text: args.text || args.body || '',
    html: args.html || undefined,
    attachments,
  };
}

async function main() {
  const args = parseArgs();

  if (args.help || args.h || !args.to) {
    console.log(`
Usage: node bin/send-smtp.mjs --to=<recipient> --subject=<subject> [options]

Options:
  --to=<email>           Recipient email address (required)
  --subject=<text>       Email subject (required)
  --body=<text>          Plain text body
  --html=<html>          HTML body (optional, overrides --body for rendering)
  --attach=<path>        File to attach (can be specified multiple times)
  --user=<email>         SMTP username (or SMTP_USER env)
  --pass=<password>      SMTP password (or SMTP_PASS env)
  --host=<host>          SMTP server (or SMTP_HOST env)
  --port=<port>          SMTP port (or SMTP_PORT env, default: 465)
  --from=<email>         From address (or SMTP_FROM env, defaults to --user)
  --help                 Show this help
    `.trim());
    return;
  }

  const transportConfig = buildTransportConfig(args);
  const message = buildMessage(args);

  if (!transportConfig.host || !transportConfig.user || !transportConfig.password) {
    console.error('Error: --host, --user, and --pass are required (or set SMTP_HOST/USER/PASS env vars)');
    process.exit(1);
  }

  console.error(`Sending via ${transportConfig.host}:${transportConfig.port} as ${transportConfig.user} → ${message.to}`);

  const result = await sendEmail(transportConfig, message);

  console.log(JSON.stringify(result, null, 2));
}

main().catch((err) => {
  console.error(err.message);
  process.exit(1);
});
