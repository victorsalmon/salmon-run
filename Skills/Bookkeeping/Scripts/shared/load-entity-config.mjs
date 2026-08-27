import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

function findConfigPath() {
  const dir = path.dirname(fileURLToPath(import.meta.url));
  const candidates = [
    path.resolve(dir, '..', '..', 'cloud-books-entities.json'),
    path.resolve(dir, '..', '..', '..', 'cloud-books-entities.json'),
  ];
  for (const c of candidates) {
    if (fs.existsSync(c)) return c;
  }
  throw new Error('cloud-books-entities.json not found');
}

let _configCache = null;

function loadConfig() {
  if (_configCache) return _configCache;
  const configPath = findConfigPath();
  const raw = fs.readFileSync(configPath, 'utf8');
  _configCache = JSON.parse(raw);
  return _configCache;
}

function loadEntityConfig(slug) {
  const config = loadConfig();
  const entity = config.entities[slug];
  if (!entity) throw new Error(`Entity "${slug}" not found in cloud-books-entities.json`);
  return entity;
}

function getEntityAccounts(slug) {
  const entity = loadEntityConfig(slug);
  return entity.bank_statement_accounts || [];
}

function getExemptCategories(slug) {
  const config = loadConfig();
  if (config.exempt_categories && config.exempt_categories[slug]) {
    return config.exempt_categories[slug];
  }
  return [];
}

function getOrgId(slug) {
  const entity = loadEntityConfig(slug);
  return entity.org_id;
}

export { loadConfig, loadEntityConfig, getEntityAccounts, getExemptCategories, getOrgId };
