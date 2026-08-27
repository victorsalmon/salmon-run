import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

function findRegistryPath() {
  const candidates = [
    path.resolve(__dirname, '..', '..', '..', 'cloud-books-entities.json'),
    path.resolve(__dirname, '..', '..', '..', '..', 'Skills', 'Bookkeeping', 'cloud-books-entities.json'),
  ];
  for (const c of candidates) {
    if (fs.existsSync(c)) return c;
  }
  throw new Error('cloud-books-entities.json (_Registry) not found');
}

const _providerCache = new Map();
let _registryData = null;

function loadRegistry() {
  if (_registryData) return _registryData;
  const registryPath = findRegistryPath();
  _registryData = JSON.parse(fs.readFileSync(registryPath, 'utf8'));
  return _registryData;
}

function listEntities() {
  const registry = loadRegistry();
  return Object.keys(registry.entities || {});
}

async function getProvider(entitySlug) {
  const cacheKey = `provider:${entitySlug}`;
  if (_providerCache.has(cacheKey)) {
    return _providerCache.get(cacheKey);
  }
  const registry = loadRegistry();
  const entity = registry.entities[entitySlug];
  if (!entity) {
    throw new Error(`Entity "${entitySlug}" not found in _Registry`);
  }
  const providerName = entity.provider || 'zoho';
  const modulePath = path.resolve(__dirname, `${providerName}-provider.mjs`);
  let ProviderClass;
  try {
    const mod = await import(`file://${modulePath}`);
    ProviderClass = mod.default || mod[`${providerName.charAt(0).toUpperCase() + providerName.slice(1)}Provider`];
  } catch (err) {
    throw new Error(`Failed to load provider "${providerName}" for entity "${entitySlug}": ${err.message}`);
  }
  if (!ProviderClass) {
    throw new Error(`Provider module "${providerName}-provider.mjs" does not export a provider class`);
  }
  const instance = new ProviderClass(entitySlug, entity);
  _providerCache.set(cacheKey, instance);
  return instance;
}

function clearCache() {
  _providerCache.clear();
}

export { getProvider, listEntities, clearCache, loadRegistry };
