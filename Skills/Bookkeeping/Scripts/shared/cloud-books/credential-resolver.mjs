import { createHash } from 'crypto';
import { execSync } from 'child_process';

const DEFAULT_REGION = 'ca-central-1';
const AWS_SM_PROFILE = 'interclaw';
const CACHE_TTL_MS = 60000;

const _credCache = new Map();

function clientNameToHash(name) {
  return createHash('sha256').update(name.toLowerCase()).digest('hex').substring(0, 16);
}

async function resolveCredentials(secretPath, options = {}) {
  const region = options.region || DEFAULT_REGION;
  const useCache = options.cache !== false;
  const cacheKey = `${secretPath}:${region}`;

  if (useCache && _credCache.has(cacheKey)) {
    const cached = _credCache.get(cacheKey);
    if (Date.now() - cached.ts < CACHE_TTL_MS) {
      return cached.data;
    }
    _credCache.delete(cacheKey);
  }

  const cmd = `aws secretsmanager get-secret-value --secret-id ${secretPath} --profile ${AWS_SM_PROFILE} --region ${region} --query "SecretString" --output text`;
  let json;
  try {
    json = execSync(cmd, { encoding: 'utf8', timeout: 15000 }).trim();
  } catch (err) {
    throw new Error(`Failed to read AWS SM secret "${secretPath}": ${err.message}`);
  }

  let secret;
  try {
    secret = JSON.parse(json);
  } catch {
    throw new Error(`Failed to parse AWS SM secret JSON for "${secretPath}"`);
  }

  if (useCache) {
    _credCache.set(cacheKey, { data: secret, ts: Date.now() });
  }

  return secret;
}

export { resolveCredentials, clientNameToHash };
