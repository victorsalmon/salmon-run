// test-idempotency.mjs — unit tests for idempotency engine
import assert from 'assert/strict';
import { tokenSetRatio, descriptionsMatch } from '../shared/cloud-books/fuzzy-match.mjs';
import { IdempotencyEngine } from '../shared/cloud-books/idempotency-engine.mjs';

// In-memory DynamoDB client mock
function createMockDynamo() {
  const store = new Map();
  return {
    async batchGetItem({ RequestItems }) {
      const tableName = Object.keys(RequestItems)[0];
      const keys = RequestItems[tableName].Keys;
      const items = [];
      for (const k of keys) {
        if (store.has(`${k.PK}#${k.SK}`)) {
          items.push(store.get(`${k.PK}#${k.SK}`));
        }
      }
      return { Responses: { [tableName]: items } };
    },
    async putItem({ Item }) {
      store.set(`${Item.PK}#${Item.SK}`, Item);
    }
  };
}

// Fuzzy match tests
assert(tokenSetRatio('TIM HORTONS 1234', 'DEBIT PURCHASE TIM HORTONS #1234 TORONTO') >= 0.6, 'similar descriptions should match');
assert(tokenSetRatio('TIM HORTONS 1234', 'AMAZON.CA 9999') < 0.6, 'different descriptions should not match');
assert(descriptionsMatch('TIM HORTONS 1234', 'TIM HORTONS #1234'), 'normalized descriptions should match');

const dynamo = createMockDynamo();
const engine = new IdempotencyEngine({ dynamoClient: dynamo, tableName: 'cll-import-journal' });

const txn1 = { account: 'chequing', date: '2026-07-13', amountCents: 12345, description: 'TIM HORTONS 1234' };
const txn2 = { account: 'chequing', date: '2026-07-13', amountCents: 12345, description: 'DEBIT PURCHASE TIM HORTONS #1234 TORONTO' };
const txn3 = { account: 'chequing', date: '2026-07-13', amountCents: 99999, description: 'SOME MERCHANT' };

// Test 1: re-import same transactions = 0 inserted
const hash1 = engine.computeHash(txn1);
await engine.record({ clientSlug: 'intersite', hash: hash1, providerTransactionId: 'zoho-1', source: 'zoho' });
const check1 = await engine.check({ clientSlug: 'intersite', transactions: [txn1] });
assert.equal(check1.toImport.length, 0, 'duplicate should not be imported');
assert.equal(check1.toSkip.length, 1, 'duplicate should be skipped');

// Test 2: cross-source same-txn different-description = skip
const check2 = await engine.check({ clientSlug: 'intersite', transactions: [txn2] });
assert.equal(check2.toImport.length, 0, 'same hash with different description should skip');

// Test 3: same-day-different-merchant same-amount = flag in provider diff
const txn4 = { account: 'chequing', date: '2026-07-13', amountCents: 12345, description: 'AMAZON.CA 9999' };
const txn5 = { account: 'savings', date: '2026-07-14', amountCents: 55555, description: 'NEW STORE' };
const providerExport = [txn1];
const diff = engine.diffAgainstProvider({ incoming: [txn2, txn4, txn5], providerExport });
assert.equal(diff.toSkip.length, 1, 'fuzzy-matched transaction should skip');
assert.equal(diff.toFlag.length, 1, 'different description same amount/date should flag');
assert.equal(diff.toImport.length, 1, 'no matching provider transaction should import');

// Test 4: genuinely new txn = insert
const newTxn = { account: 'savings', date: '2026-07-14', amountCents: 55555, description: 'NEW STORE' };
const check3 = await engine.check({ clientSlug: 'intersite', transactions: [newTxn] });
assert.equal(check3.toImport.length, 1, 'new transaction should be imported');

// Preview shape
const preview = engine.generatePreview({ toImport: [newTxn], toSkip: [], toFlag: [] });
assert.equal(preview.summary.insert, 1);
assert.equal(preview.summary.skip, 0);
assert.equal(preview.summary.flag, 0);
assert.ok(preview.insert[0].hash, 'preview entries include hash');

console.log('All idempotency tests passed.');
