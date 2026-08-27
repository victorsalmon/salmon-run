const fs = require('fs');
const { spawnSync } = require('child_process');
const sleep = ms => new Promise(r => setTimeout(r, ms));
const SLEEP_MS = 500;

class ZohoExpenses {
  constructor(auth) {
    this.auth = auth;
  }

  async create(orgId, { accountId, paidThroughAccountId, vendorId, amount, date, description }) {
    // Description convention: "{Vendor} — {CAD$} — {Date}" for expenses
    // Never pass empty string — blank descriptions break audit trail
    const body = {
      account_id: accountId,
      paid_through_account_id: paidThroughAccountId,
      amount: Math.abs(amount),
      date,
      description: description || '(no description)',
      is_billable: false
    };
    if (vendorId) body.vendor_id = vendorId;
    const res = await fetch(this.auth.apiUrl('/expenses', orgId), {
      method: 'POST',
      headers: this.auth.headers,
      body: JSON.stringify(body)
    });
    const data = await res.json();
    if (!data || typeof data.code === 'undefined') throw new Error(`Create expense failed — unexpected response: ${JSON.stringify(data)}`);
    if (data.code !== 0) throw new Error(`Create expense failed: ${data.message}`);
    await sleep(SLEEP_MS);
    return data.expense.expense_id;
  }

  async uploadReceipt(orgId, expenseId, filePath) {
    const url = `https://www.zohoapis.com/books/v3/expenses/${expenseId}/receipt?organization_id=${orgId}`;
    const token = await this.auth.getToken();

    const curlCheck = spawnSync('curl', ['--version'], { encoding: 'utf8', timeout: 5000, shell: false });
    if (curlCheck.error || curlCheck.status !== 0) throw new Error('curl is required but not found in PATH');

    const args = [
      '-s', '-X', 'POST',
      '-H', `Authorization: Zoho-oauthtoken ${token}`,
      '-F', `receipt=@${filePath}`,
      '--connect-timeout', '30',
      '--max-time', '60',
      url
    ];
    const result = spawnSync('curl', args, { encoding: 'utf8', timeout: 90000, shell: false });
    if (result.error) throw new Error(`curl failed: ${result.error.message}`);
    if (result.status !== 0) throw new Error(`curl exited ${result.status}: ${result.stderr}`);
    const rawOut = result.stdout || '';
    let data;
    try { data = JSON.parse(rawOut); } catch (e) { throw new Error(`Failed to parse curl response: ${rawOut.substring(0, 500)}`); }
    if (!data || typeof data.code === 'undefined') throw new Error(`Receipt upload — unexpected response: ${JSON.stringify(data)}`);
    if (data.code !== 0) console.warn(`    [WARN] Receipt upload returned code ${data.code}: ${data.message}`);
    await sleep(SLEEP_MS);
    return data.code === 0;
  }
}

module.exports = { ZohoExpenses };
