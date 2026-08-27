const fs = require('fs');
const path = require('path');
const CONTACTS_CACHE_PATH = '.zoho-contacts-cache.json';

class ZohoContacts {
  constructor(auth, stateDir) {
    this.auth = auth;
    this.cachePath = path.join(stateDir || '.', CONTACTS_CACHE_PATH);
    this.cache = {};
    this._loadCache();
  }

  _loadCache() {
    try { this.cache = JSON.parse(fs.readFileSync(this.cachePath, 'utf8')); } catch { this.cache = {}; }
  }

  _saveCache() {
    fs.mkdirSync(path.dirname(this.cachePath), { recursive: true });
    fs.writeFileSync(this.cachePath, JSON.stringify(this.cache, null, 2));
  }

  async ensureContact(orgId, vendorName) {
    const key = `${orgId}:${vendorName.toLowerCase().trim()}`;
    if (this.cache[key]) return this.cache[key];

    try {
      const searchUrl = this.auth.apiUrl(`/contacts?contact_name=${encodeURIComponent(vendorName)}`, orgId);
      const searchRes = await fetch(searchUrl, { headers: this.auth.headers });
      const searchData = await searchRes.json();
      if (searchData.contacts && searchData.contacts.length > 0) {
        this.cache[key] = searchData.contacts[0].contact_id;
        this._saveCache();
        return this.cache[key];
      }
    } catch { /* search failed, continue to create attempt */ }

    try {
      const createRes = await fetch(this.auth.apiUrl('/contacts', orgId), {
        method: 'POST',
        headers: this.auth.headers,
        body: JSON.stringify({ contact_name: vendorName, contact_type: 'vendor' })
      });
      const createData = await createRes.json();
      if (createData.code === 0) {
        this.cache[key] = createData.contact.contact_id;
        this._saveCache();
        return this.cache[key];
      }
    } catch { /* creation not permitted — proceed without vendor_id */ }

    return null;
  }
}

module.exports = { ZohoContacts };
