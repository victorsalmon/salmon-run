import fs from 'fs';
import path from 'path';
import { execSync } from 'child_process';

const SECRET_NAMES = [
  'ZOHO_BOOKS_ID',
  'ZOHO_BOOKS_SECRET',
  'ZOHO_BOOKS_REFRESH',
  'ZOHO_BOOKS_ORG_INTERSITE',
  'ZOHO_BOOKS_ORG_RENTALS'
];

const ORG_MAP = {
  'intersite-consulting': 'ZOHO_BOOKS_ORG_INTERSITE',
  'room-rentals': 'ZOHO_BOOKS_ORG_RENTALS'
};

const FALLBACK_ORG_IDS = {
  'intersite-consulting': '925048093',
  'room-rentals': '925004567'
};

const AWS_SM_SECRET_ID = 'Interclaw/FRAD/Provisioning';
const AWS_SM_PROFILE = 'interclaw';
const AWS_SM_REGION = 'ca-central-1';

const AWS_SM_KEY_MAP = {
  'ZOHO_BOOKS_ID': 'ZOHO_BOOKS_ID',
  'ZOHO_BOOKS_SECRET': 'ZOHO_BOOKS_SECRET',
  'ZOHO_BOOKS_REFRESH': 'ZOHO_BOOKS_REFRESH',
  'ZOHO_BOOKS_ORG_INTERSITE': 'ZOHO_BOOKS_ORG_ID',
  'ZOHO_BOOKS_ORG_RENTALS': 'RECEIPTS_RENTALS_ORG_ID'
};

function readFromProxyContainer() {
  const containerId = execSync(
    'docker ps --filter name=FRAD_api-proxy --format "{{.ID}}"',
    { encoding: 'utf8' }
  ).trim();
  if (!containerId) {
    throw new Error('FRAD_api-proxy container not found — is the fleet running?');
  }

  const bundleJson = execSync(
    `docker exec ${containerId} cat /run/secrets/secrets_bundle`,
    { encoding: 'utf8', timeout: 10000 }
  );

  let bundle;
  try {
    bundle = JSON.parse(bundleJson);
  } catch {
    throw new Error('Failed to parse proxy secrets bundle');
  }

  const creds = {};
  for (const name of SECRET_NAMES) {
    if (!bundle[name]) {
      throw new Error(`Required secret "${name}" not found in proxy secrets bundle`);
    }
    creds[name] = bundle[name];
  }
  return creds;
}

function readFromAwsSm() {
  const cmd = `aws secretsmanager get-secret-value --secret-id ${AWS_SM_SECRET_ID} --profile ${AWS_SM_PROFILE} --region ${AWS_SM_REGION} --query "SecretString" --output text`;
  const json = execSync(cmd, { encoding: 'utf8', timeout: 15000 }).trim();
  let secret;
  try {
    secret = JSON.parse(json);
  } catch {
    throw new Error('Failed to parse AWS SM secret JSON');
  }

  const creds = {};
  for (const name of SECRET_NAMES) {
    const smKey = AWS_SM_KEY_MAP[name];
    const value = secret[smKey];
    if (value && value.trim()) {
      creds[name] = value.trim();
    } else if (FALLBACK_ORG_IDS[name.replace('ZOHO_BOOKS_ORG_', '').toLowerCase().replace('rentals', 'room-rentals').replace('intersite', 'intersite-consulting')]) {
      const entityKey = name.replace('ZOHO_BOOKS_ORG_', '').toLowerCase();
      const entity = entityKey === 'rentals' ? 'room-rentals' : entityKey === 'intersite' ? 'intersite-consulting' : null;
      if (entity && FALLBACK_ORG_IDS[entity]) {
        creds[name] = FALLBACK_ORG_IDS[entity];
      }
    } else {
      throw new Error(`Required secret "${name}" not found in AWS SM secret "${AWS_SM_SECRET_ID}"`);
    }
  }
  return creds;
}

function resolveSync(options = {}) {
  try {
    return readFromProxyContainer();
  } catch {
    return readFromAwsSm();
  }
}

function getOrgId(creds, entitySlug) {
  const key = ORG_MAP[entitySlug] || ORG_MAP['intersite-consulting'];
  return creds[key];
}

export { resolveSync, getOrgId, SECRET_NAMES, ORG_MAP };
