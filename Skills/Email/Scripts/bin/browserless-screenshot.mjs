import { readFileSync, existsSync, writeFileSync, mkdirSync } from 'fs';
import { join } from 'path';

const ingestDir = 'C:\\Users\\Victor\\intersite-docs\\Taxes and Bookkeeping\\room-rentals\\2026 Receipts\\ingest';
const files = ['2026-01-12 - 80.44 - Facebook Meta', '2026-01-29 - 172.20 - Facebook Meta', '2026-02-10 - 59.08 - Facebook Meta', '2026-02-24 - 172.20 - Facebook Meta', '2026-03-10 - 33.82 - Facebook Meta', '2026-05-11 - 66.30 - Facebook Meta'];

// Get browserless token from env
const TOKEN = process.env.BROWSERLESS_API_KEY || '';

function escapeQuotes(str) {
  return str.replace(/'/g, "'\\''");
}

async function main() {
  if (!TOKEN) { console.error('BROWSERLESS_API_KEY env required'); process.exit(1); }

  // Get container ID once
  const { execSync } = await import('child_process');
  const psOut = execSync('docker ps --filter name=FRAD_mcp_browserless --format {{.ID}}', { encoding: 'utf8' }).trim();
  const containerId = psOut.split('\n')[0].trim();
  if (!containerId) { console.error('Browserless container not found'); process.exit(1); }
  console.error(`Container: ${containerId}`);

  for (const base of files) {
    const htmlPath = join(ingestDir, `${base}.html`);
    if (!existsSync(htmlPath)) { console.error(`Missing ${htmlPath}`); continue; }

    // Write HTML to temp file inside container
    const tmpHtml = `/tmp/input_${base.replace(/[^a-zA-Z0-9._-]/g, '_')}.html`;
    const tmpJpg = `/tmp/output_${base.replace(/[^a-zA-Z0-9._-]/g, '_')}.jpg`;

    try {
      execSync(`docker cp "${htmlPath}" ${containerId}:${tmpHtml}`, { encoding: 'utf8', timeout: 10000 });
    } catch (e) {
      console.error(`docker cp failed for ${base}: ${e.message}`);
      continue;
    }

    // Read HTML and screenshot via Browserless inline
    const script = `const fs = require('fs');
const html = fs.readFileSync('${tmpHtml}', 'utf8');
const http = require('http');
const data = JSON.stringify({ html, options: { type: 'jpeg', quality: 80, fullPage: true, defaultViewport: { width: 800, height: 600 } } });
const req = http.request({ hostname: 'localhost', port: 3003, path: '/screenshot?token=${TOKEN}', method: 'POST', headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(data) } }, (res) => {
  const chunks = [];
  res.on('data', c => chunks.push(c));
  res.on('end', () => {
    if (res.statusCode === 200) {
      fs.writeFileSync('${tmpJpg}', Buffer.concat(chunks));
      console.log('OK');
    } else {
      console.log('ERROR ' + res.statusCode + ' ' + Buffer.concat(chunks).toString());
    }
  });
});
req.write(data);
req.end();`;

    const scriptPath = `/tmp/scr_${base.replace(/[^a-zA-Z0-9._-]/g, '_')}.js`;
    try {
      execSync(`docker exec ${containerId} sh -c 'cat > ${scriptPath} << '"'"'SCRIPT'"'"'
${script}
'"'"'SCRIPT'"'"''`, { encoding: 'utf8', timeout: 10000 });
      const result = execSync(`docker exec ${containerId} node ${scriptPath}`, { encoding: 'utf8', timeout: 30000 });
      if (result.trim() === 'OK') {
        execSync(`docker cp ${containerId}:${tmpJpg} "${join(ingestDir, `${base}.jpg`)}"`, { encoding: 'utf8', timeout: 10000 });
        console.log(`Generated ${base}.jpg`);
      } else {
        console.error(`Failed ${base}: ${result}`);
      }
    } catch (e) {
      console.error(`Error for ${base}: ${e.message}`);
    } finally {
      try { execSync(`docker exec ${containerId} rm -f ${tmpHtml} ${tmpJpg} ${scriptPath}`, { encoding: 'utf8', timeout: 5000 }); } catch {}
    }
  }
}

main().catch(e => { console.error(e); process.exit(1); });
