// fuzzy-match.mjs — token-set ratio helper for description similarity

const STOPWORDS = new Set([
  'the', 'a', 'an', 'and', 'or', 'of', 'in', 'on', 'at', 'to', 'for', 'with',
  'debit', 'purchase', 'payment', 'transaction', 'pos', 'card', 'visa',
  'mc', 'mastercard', 'interac', 'e-transfer', 'etransfer'
]);

export function tokenize(str) {
  if (typeof str !== 'string') return new Set();
  const tokens = str
    .toLowerCase()
    .replace(/[^a-z0-9\s]/g, ' ')
    .split(/\s+/)
    .filter(Boolean)
    .filter(t => !STOPWORDS.has(t));
  return new Set(tokens);
}

export function tokenSetRatio(a, b) {
  const setA = tokenize(a);
  const setB = tokenize(b);
  if (setA.size === 0 && setB.size === 0) return 1.0;
  if (setA.size === 0 || setB.size === 0) return 0.0;

  const intersection = new Set([...setA].filter(x => setB.has(x)));
  const union = new Set([...setA, ...setB]);
  return intersection.size / union.size;
}

export const DESCRIPTION_MATCH_THRESHOLD = 0.6;

export function descriptionsMatch(a, b) {
  return tokenSetRatio(a, b) >= DESCRIPTION_MATCH_THRESHOLD;
}
