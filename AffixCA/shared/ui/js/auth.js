/* ============================================================================
   Affix/CA  ·  auth.js  —  Client-side authentication wrapper
   Manages tokens in localStorage, wraps fetch() with Bearer auth,
   and auto-redirects to /login on 401.
   Must be loaded BEFORE app.js.
   ============================================================================ */

'use strict';

window.AffixAuth = {
  TOKEN_KEY: 'affixca_auth_token',
  USER_KEY:  'affixca_auth_user',

  getToken()  { return localStorage.getItem(this.TOKEN_KEY); },
  getUser()   { try { return JSON.parse(localStorage.getItem(this.USER_KEY)); } catch { return null; } },

  setSession(token, user) {
    localStorage.setItem(this.TOKEN_KEY, token);
    localStorage.setItem(this.USER_KEY, JSON.stringify(user));
  },

  clear() {
    localStorage.removeItem(this.TOKEN_KEY);
    localStorage.removeItem(this.USER_KEY);
  },

  async logout() {
    const token = this.getToken();
    if (token) {
      try {
        await _origFetch('/api/auth/logout', {
          method: 'POST',
          headers: { 'Authorization': 'Bearer ' + token }
        });
      } catch {}
    }
    this.clear();
    window.location.href = '/login';
  }
};

// ── Global fetch wrapper — inject Bearer token, handle 401 ──────────────────
const _origFetch = window.fetch;
window.fetch = function (url, opts) {
  opts = opts || {};
  const token = AffixAuth.getToken();
  if (token) {
    if (!opts.headers) opts.headers = {};
    if (opts.headers instanceof Headers) {
      if (!opts.headers.has('Authorization')) opts.headers.set('Authorization', 'Bearer ' + token);
    } else {
      if (!opts.headers['Authorization']) opts.headers['Authorization'] = 'Bearer ' + token;
    }
  }
  return _origFetch.call(this, url, opts).then(res => {
    if (res.status === 401 && typeof url === 'string' &&
        !url.includes('/api/auth/login') && !url.includes('/api/auth/session')) {
      AffixAuth.clear();
      window.location.href = '/login';
    }
    return res;
  });
};

// ── Session guard — redirect to login if no token ───────────────────────────
if (!localStorage.getItem('affixca_auth_token')) {
  window.location.href = '/login';
}
