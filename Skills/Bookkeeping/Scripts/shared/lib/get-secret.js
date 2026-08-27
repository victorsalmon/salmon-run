const { execFileSync } = require('child_process');

const SECRET_ID = 'Interclaw/FRAD/Provisioning';
const AWS_REGION = () => process.env.AWS_REGION || 'ca-central-1';

function getSecret() {
  const args = [
    'secretsmanager', 'get-secret-value',
    '--secret-id', SECRET_ID,
    '--region', AWS_REGION(),
    '--query', 'SecretString',
    '--output', 'text'
  ];
  // Env-based long-lived credentials are the unattended-friendly path
  // (container IAM or dev-daily-fixed). Only add a profile flag when one was
  // explicitly configured — never silently route to the interactive
  // `interclaw` SSO profile, which unattended Bookkeeping containers cannot
  // complete.
  if (process.env.AWS_PROFILE) {
    args.push('--profile', process.env.AWS_PROFILE);
  }
  try {
    const stdout = execFileSync('aws', args, { encoding: 'utf8', timeout: 15000 });
    return JSON.parse(stdout.trim());
  } catch (err) {
    const profile = process.env.AWS_PROFILE || '(env credentials)';
    const stderr = (err.stderr && err.stderr.toString().trim()) || err.message || '';
    const guidance =
      'AWS SSO session expired or credentials unavailable — run `aws sso login` ' +
      'or refresh the `dev-daily-fixed` long-lived credentials, then retry.';
    const wrapped = new Error(
      `Failed to fetch secret '${SECRET_ID}' using profile '${profile}' in region '${AWS_REGION()}': ${guidance}`
    );
    wrapped.cause = stderr;
    throw wrapped;
  }
}

module.exports = { getSecret, SECRET_ID };
