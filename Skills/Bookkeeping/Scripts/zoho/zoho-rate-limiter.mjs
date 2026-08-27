export class ZohoRateLimiter {
  constructor(options = {}) {
    this.minGapMs = options.minGapMs || 300;
    this.batchSleepMs = options.batchSleepMs || 2000;
    this.lastCall = 0;
    this.callCount = 0;
    this.startTime = Date.now();
  }

  async wait() {
    const now = Date.now();
    const elapsed = now - this.lastCall;
    if (elapsed < this.minGapMs) {
      await sleep(this.minGapMs - elapsed);
    }
    this.lastCall = Date.now();
    this.callCount++;
  }

  async batchWait() {
    await this.wait();
    if (this.callCount > 0 && this.callCount % 10 === 0) {
      await sleep(this.batchSleepMs);
    }
  }

  async fetchWithRetry(url, options = {}) {
    const maxRetries = 3;
    let lastResponse = null;
    for (let attempt = 0; attempt <= maxRetries; attempt++) {
      await this.batchWait();
      let response;
      try {
        response = await fetch(url, options);
      } catch (err) {
        // Network-level failure (DNS, refused, undici timeout) — retry.
        if (attempt < maxRetries) {
          const delay = Math.pow(2, attempt) * 1000;
          console.warn(`  Network error (${err.message}) — retry ${attempt + 1}/${maxRetries} after ${delay}ms`);
          await sleep(delay);
          continue;
        }
        throw err;
      }
      lastResponse = response;
      const retryable = response.status === 429 || response.status >= 500;
      if (retryable && attempt < maxRetries) {
        const delay = Math.pow(2, attempt) * 1000;
        console.warn(`  Zoho returned ${response.status} — retry ${attempt + 1}/${maxRetries} after ${delay}ms`);
        await sleep(delay);
        continue;
      }
      return response;
    }
    return lastResponse;
  }

  get stats() {
    const elapsed = (Date.now() - this.startTime) / 1000;
    return {
      totalCalls: this.callCount,
      elapsedSec: Math.round(elapsed),
      avgGapMs: this.callCount > 0 ? Math.round(elapsed * 1000 / this.callCount) : 0
    };
  }
}

function sleep(ms) {
  return new Promise(r => setTimeout(r, ms));
}
