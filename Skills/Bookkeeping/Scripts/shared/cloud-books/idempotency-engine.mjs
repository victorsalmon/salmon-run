// idempotency-engine.mjs — guarantees zero duplicate provider transactions
import crypto from 'crypto';
import { tokenSetRatio, DESCRIPTION_MATCH_THRESHOLD } from './fuzzy-match.mjs';

export class IdempotencyEngine {
  constructor({ dynamoClient, tableName = 'cll-import-journal' }) {
    this.dynamoClient = dynamoClient;
    this.tableName = tableName;
  }

  computeHash({ account, date, amountCents }) {
    const payload = `${account}\u{2016}${date}\u{2016}${amountCents}`;
    return crypto.createHash('sha256').update(payload).digest('hex');
  }

  async _batchGet(clientSlug, hashes) {
    const known = new Set();
    if (!hashes.length) return known;

    const keys = hashes.map(hash => ({ PK: clientSlug, SK: hash }));
    const response = await this.dynamoClient.batchGetItem({
      RequestItems: {
        [this.tableName]: {
          Keys: keys,
          ProjectionExpression: 'SK'
        }
      }
    });

    const items = response.Responses?.[this.tableName] || [];
    for (const item of items) {
      known.add(item.SK);
    }
    return known;
  }

  async check({ clientSlug, transactions }) {
    const hashed = transactions.map(t => ({
      ...t,
      hash: this.computeHash(t)
    }));
    const hashes = hashed.map(h => h.hash);
    const known = await this._batchGet(clientSlug, hashes);

    const toImport = [];
    const toSkip = [];
    for (const t of hashed) {
      if (known.has(t.hash)) {
        toSkip.push(t);
      } else {
        toImport.push(t);
      }
    }
    return { toImport, toSkip, toFlag: [] };
  }

  diffAgainstProvider({ incoming, providerExport }) {
    const providerByKey = new Map();
    for (const t of providerExport) {
      const key = `${t.date}|${t.amountCents}`;
      if (!providerByKey.has(key)) providerByKey.set(key, []);
      providerByKey.get(key).push(t);
    }

    const toImport = [];
    const toSkip = [];
    const toFlag = [];

    for (const t of incoming) {
      const key = `${t.date}|${t.amountCents}`;
      const matches = providerByKey.get(key) || [];

      if (matches.length === 0) {
        toImport.push(t);
      } else if (matches.length === 1) {
        const ratio = tokenSetRatio(t.description || '', matches[0].description || '');
        if (ratio >= DESCRIPTION_MATCH_THRESHOLD) {
          toSkip.push(t);
        } else {
          toFlag.push({ ...t, reason: 'similar_date_amount_different_description', match: matches[0] });
        }
      } else {
        const best = matches
          .map(m => ({ match: m, ratio: tokenSetRatio(t.description || '', m.description || '') }))
          .sort((a, b) => b.ratio - a.ratio)[0];
        if (best && best.ratio >= DESCRIPTION_MATCH_THRESHOLD) {
          toSkip.push(t);
        } else {
          toFlag.push({ ...t, reason: 'multiple_provider_matches', matches });
        }
      }
    }

    return { toImport, toSkip, toFlag };
  }

  generatePreview({ toImport, toSkip, toFlag }) {
    return {
      summary: {
        insert: toImport.length,
        skip: toSkip.length,
        flag: toFlag.length
      },
      insert: toImport.map(t => ({ hash: t.hash || this.computeHash(t), ...t })),
      skip: toSkip.map(t => ({ hash: t.hash || this.computeHash(t), ...t })),
      flag: toFlag.map(t => ({ hash: t.hash || this.computeHash(t), ...t }))
    };
  }

  async record({ clientSlug, hash, providerTransactionId, source }) {
    await this.dynamoClient.putItem({
      TableName: this.tableName,
      Item: {
        PK: clientSlug,
        SK: hash,
        providerTransactionId,
        source,
        importedAt: new Date().toISOString()
      }
    });
  }
}
