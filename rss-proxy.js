// ─────────────────────────────────────────────────────────────
// rss-proxy.js — Proxy RSS léger pour NAS Synology / Node.js
// Contourne les WAF gouvernementaux (safeonweb.be, cert.ssi.gouv.fr)
// en faisant les requêtes côté serveur avec un User-Agent browser réaliste
//
// Usage : node rss-proxy.js
// Port  : 3033 (configurable via PORT env)
// CORS  : autorisé pour l'origine de ton app QR Certify
// ─────────────────────────────────────────────────────────────

const http  = require('http');
const https = require('https');
const url   = require('url');

const PORT = process.env.PORT || 3033;

// Feeds autorisés — liste blanche stricte
const ALLOWED_FEEDS = new Set([
  'https://www.safeonweb.be/fr/rss',
  'https://safeonweb.be/fr/rss',
  'https://www.cert.ssi.gouv.fr/feed/',
  'https://www.cert.ssi.gouv.fr/alerte/feed/',
  'https://www.cybermalveillance.gouv.fr/feed/atom-flux-actualites',
  'https://www.cybermalveillance.gouv.fr/feed/atom-flux-alertes',
  'https://www.zataz.com/category/arnaque/feed/',
  'https://www.undernews.fr/feed',
  'https://cyber.gouv.fr/actualites/rss/',
]);

const HEADERS_OUT = {
  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
  'Accept': 'application/rss+xml, application/atom+xml, application/xml, text/xml, */*',
  'Accept-Language': 'fr-BE,fr;q=0.9,en;q=0.8',
  'Accept-Encoding': 'identity',
  'Cache-Control': 'no-cache',
  'Referer': 'https://www.google.com/',
};

// Ton origine QR Certify — adapte si tu la déploies ailleurs
const ALLOWED_ORIGINS = [
  'null',                         // fichier local (file://)
  'http://localhost',
  'http://127.0.0.1',
  // Ajoute ici ton domaine GitHub Pages si déployé :
  // 'https://itshutdown2020-bit.github.io',
];

function fetchFeed(targetUrl, res) {
  const parsed = url.parse(targetUrl);
  const lib    = parsed.protocol === 'https:' ? https : http;

  const req = lib.request({
    hostname: parsed.hostname,
    port:     parsed.port || (parsed.protocol === 'https:' ? 443 : 80),
    path:     parsed.path,
    method:   'GET',
    headers:  HEADERS_OUT,
  }, upstream => {
    // Suivre les redirections 301/302
    if ([301, 302, 303, 307, 308].includes(upstream.statusCode) && upstream.headers.location) {
      const redirectUrl = upstream.headers.location.startsWith('http')
        ? upstream.headers.location
        : `${parsed.protocol}//${parsed.hostname}${upstream.headers.location}`;
      console.log(`↪ Redirect → ${redirectUrl}`);
      return fetchFeed(redirectUrl, res);
    }

    res.writeHead(upstream.statusCode, {
      'Content-Type':                upstream.headers['content-type'] || 'application/xml',
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods':'GET, OPTIONS',
      'Cache-Control':               'public, max-age=900', // 15 min cache
      'X-Proxy-Source':              targetUrl,
    });
    upstream.pipe(res);
  });

  req.on('error', err => {
    console.error(`Erreur fetch ${targetUrl}:`, err.message);
    res.writeHead(502, { 'Content-Type': 'text/plain', 'Access-Control-Allow-Origin': '*' });
    res.end(`Erreur proxy: ${err.message}`);
  });

  req.setTimeout(10000, () => {
    req.destroy();
    if (!res.headersSent) {
      res.writeHead(504, { 'Content-Type': 'text/plain', 'Access-Control-Allow-Origin': '*' });
      res.end('Timeout');
    }
  });

  req.end();
}

const server = http.createServer((req, res) => {
  // CORS preflight
  if (req.method === 'OPTIONS') {
    res.writeHead(204, {
      'Access-Control-Allow-Origin':  '*',
      'Access-Control-Allow-Methods': 'GET, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type',
      'Access-Control-Max-Age':       '86400',
    });
    return res.end();
  }

  if (req.method !== 'GET') {
    res.writeHead(405, { 'Content-Type': 'text/plain' });
    return res.end('Method Not Allowed');
  }

  const parsed  = url.parse(req.url, true);
  const target  = parsed.query.url || parsed.query.quest;

  // Health check
  if (parsed.pathname === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({ status: 'ok', feeds: [...ALLOWED_FEEDS] }));
  }

  if (!target) {
    res.writeHead(400, { 'Content-Type': 'text/plain' });
    return res.end('Paramètre ?url= manquant\nEx: http://localhost:3033/?url=https://www.safeonweb.be/fr/rss');
  }

  // Vérification liste blanche
  if (!ALLOWED_FEEDS.has(target)) {
    console.warn(`⛔ URL non autorisée: ${target}`);
    res.writeHead(403, { 'Content-Type': 'text/plain', 'Access-Control-Allow-Origin': '*' });
    return res.end(`URL non autorisée: ${target}`);
  }

  console.log(`→ Fetch: ${target}`);
  fetchFeed(target, res);
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`✅ RSS Proxy démarré sur http://0.0.0.0:${PORT}`);
  console.log(`   Feeds autorisés: ${ALLOWED_FEEDS.size}`);
  console.log(`   Test: http://localhost:${PORT}/?url=https://www.safeonweb.be/fr/rss`);
  console.log(`   Health: http://localhost:${PORT}/health`);
});
