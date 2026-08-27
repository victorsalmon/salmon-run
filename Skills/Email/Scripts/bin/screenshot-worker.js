const fs = require('fs');
const http = require('http');

const TOKEN = process.env.BT || '';
const htmlFile = process.argv[2];
const outFile = process.argv[3];

if (!htmlFile || !outFile) {
  console.error('Usage: node worker.js <htmlFile> <outFile>');
  process.exit(1);
}

const html = fs.readFileSync(htmlFile, 'utf8');
const payload = JSON.stringify({
  html: html,
  options: { type: 'jpeg', quality: 80, fullPage: true }
});

const req = http.request({
  hostname: 'localhost', port: 3003,
  path: `/screenshot?token=${TOKEN}`,
  method: 'POST',
  headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload) }
}, (res) => {
  const chunks = [];
  res.on('data', c => chunks.push(c));
  res.on('end', () => {
    const buf = Buffer.concat(chunks);
    if (res.statusCode === 200) {
      fs.writeFileSync(outFile, buf);
      console.log('OK');
    } else {
      console.error(`HTTP ${res.statusCode}: ${buf.toString().slice(0, 200)}`);
    }
  });
});
req.on('error', e => { console.error('Request error:', e.message); });
req.write(payload);
req.end();
