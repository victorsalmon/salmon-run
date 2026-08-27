// Used by: Skills/Bookkeeping/books/reconciliation/prp-stage7-cloud-alignment.md § Sub-stage 7d (field discovery)
import { ZohoAuth } from './zoho-auth.js';
import { fetchWithAudit } from './lib/audit-logger.mjs';

async function main() {
  const auth = await ZohoAuth.ensureAuth();
  await auth.getToken();
  const orgId = '925004567';
  
  // Check banktransaction fields for each account
  const accounts = [
    { id: '151803000000101245', name: 'RBC-FRA' },
    { id: '151803000000101251', name: 'RBC-VISA' },
    { id: '151803000000101153', name: 'SCOTIA-TMH' },
    { id: '151803000000101006', name: 'TD-MLM' },
  ];

  for (const acct of accounts) {
    const resp = await fetchWithAudit(
      `https://www.zohoapis.com/books/v3/banktransactions?organization_id=${orgId}&bank_account_id=${acct.id}&page=1&per_page=3`,
      { headers: auth.headers },
      { domain: 'Bookkeeper', action: 'zoho:banktransactions:list' }
    );
    const data = resp.data;
    if (data.code !== 0 || !data.banktransactions?.length) {
      console.log(`${acct.name}: no txns or error`);
      continue;
    }
    const t = data.banktransactions[0];
    console.log(`${acct.name}:`);
    console.log(`  transaction_id: ${t.transaction_id}`);
    console.log(`  bank_transaction_id: ${t.bank_transaction_id}`);
    console.log(`  date: ${t.transaction_date}`);
    console.log(`  amount: ${t.amount}`);
    console.log(`  debit_or_credit: ${t.debit_or_credit}`);
    console.log(`  status: ${t.status}`);
    console.log(`  is_imported: ${t.is_imported}`);
    console.log(`  transaction_type: ${t.transaction_type}`);
    console.log(`  payee: ${t.payee}`);
    console.log(`  description: ${t.description}`);
    console.log(`  reference_number: ${t.reference_number}`);
    console.log(`  customer_id: ${t.customer_id}`);
    console.log(`  vendor_id: ${t.vendor_id}`);
    console.log(`  account_id: ${t.account_id}`);
    console.log(`  account_name: ${t.account_name}`);
    console.log(`  currency_id: ${t.currency_id}`);
    console.log(`  exchange_rate: ${t.exchange_rate}`);
    console.log(`  rate: ${t.rate}`);
    console.log(`  is_initial_balance: ${t.is_initial_balance}`);
    console.log(`All keys: ${Object.keys(t).join(', ')}`);
  }
}
main().catch(e => { console.error('ERR:', e.message, e.stack); process.exit(1); });
