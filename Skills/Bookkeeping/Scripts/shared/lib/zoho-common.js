const fs = require('fs');
const path = require('path');

function parseArgs() {
  const args = {};
  for (let i = 2; i < process.argv.length; i++) {
    const a = process.argv[i];
    if (a.startsWith('--')) {
      const k = a.slice(2);
      const v = i + 1 < process.argv.length && !process.argv[i + 1].startsWith('--') ? process.argv[++i] : true;
      args[k] = v;
    }
  }
  return args;
}

function loadEntityConfig(entity) {
  const scriptDir = path.dirname(process.argv[1]);
  const candidates = [
    path.join(scriptDir, '..', '..', '..', 'cloud-books-entities.json'),
    path.resolve(scriptDir, '..', '..', '..', 'cloud-books-entities.json'),
  ];
  let configPath = null;
  for (const c of candidates) {
    if (fs.existsSync(c)) { configPath = c; break; }
  }
  if (!configPath) throw new Error('cloud-books-entities.json not found');
  const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
  const ec = config.entities[entity];
  if (!ec) throw new Error(`Entity '${entity}' not found in config`);
  return { config, ec };
}

function sleep(ms) {
  return new Promise(r => setTimeout(r, ms));
}

module.exports = { parseArgs, loadEntityConfig, sleep };
