#!/usr/bin/env node

// =============================================================================
// server.js — flora64 production static-file server
//
// Zero-dependency Node.js HTTP server for the Vite-built frontend.
// Deployed alongside the static files — serves them from __dirname.
//
// Features:
//   - proper MIME types for .wasm, .js, .css
//   - Cross-Origin-Opener-Policy / Cross-Origin-Embedder-Policy headers
//     (required for WASM cross-origin isolation in the browser)
//   - gzip / brotli pre-compressed files (Vite generates .gz / .br variants)
//   - SPA fallback (serves index.html for unrecognised routes)
// =============================================================================

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// --------------- Configuration ------------------------------------------------
const ROOT = path.dirname(fileURLToPath(import.meta.url));

const PORT = parseInt(process.env.PORT, 10) || 3000;
const HOST = process.env.HOST || '0.0.0.0';

// --------------- MIME types ---------------------------------------------------
const MIME = {
  '.html':      'text/html; charset=utf-8',
  '.js':        'application/javascript; charset=utf-8',
  '.css':       'text/css; charset=utf-8',
  '.json':      'application/json; charset=utf-8',
  '.wasm':      'application/wasm',
  '.svg':       'image/svg+xml',
  '.png':       'image/png',
  '.ico':       'image/x-icon',
  '.woff2':     'font/woff2',
  '.woff':      'font/woff',
};

// --------------- Request handler ----------------------------------------------
function serve(req, res) {
  // Strip query string / hash
  let url = req.url.split('?')[0].split('#')[0];

  // Default to index.html for SPA fallback
  if (url === '/') url = '/index.html';

  const filePath = path.join(ROOT, url);

  // Security: prevent path traversal outside ROOT
  if (!filePath.startsWith(ROOT)) {
    res.writeHead(403);
    res.end('Forbidden');
    return;
  }

  // Determine MIME type
  const ext = path.extname(filePath).toLowerCase();
  const contentType = MIME[ext] || 'application/octet-stream';

  // Check for pre-compressed variants (Vite generates .gz and .br)
  const acceptEncoding = req.headers['accept-encoding'] || '';
  let compressed = null;

  if (/\bbr\b/.test(acceptEncoding) && fs.existsSync(filePath + '.br')) {
    compressed = 'br';
  } else if (/\bgzip\b/.test(acceptEncoding) && fs.existsSync(filePath + '.gz')) {
    compressed = 'gzip';
  }

  const readPath = compressed ? filePath + '.' + compressed : filePath;

  fs.readFile(readPath, (err, data) => {
    if (err) {
      if (err.code === 'ENOENT') {
        // SPA fallback: serve index.html for unrecognised routes
        if (url !== '/index.html') {
          const indexPath = path.join(ROOT, 'index.html');
          return fs.readFile(indexPath, (err2, indexData) => {
            if (err2) {
              res.writeHead(500);
              res.end('Internal Server Error');
              return;
            }
            res.writeHead(200, {
              'Content-Type': 'text/html; charset=utf-8',
              'Cross-Origin-Opener-Policy': 'same-origin',
              'Cross-Origin-Embedder-Policy': 'require-corp',
            });
            res.end(indexData);
          });
        }
        res.writeHead(404);
        res.end('Not Found');
        return;
      }
      res.writeHead(500);
      res.end('Internal Server Error');
      return;
    }

    const headers = {
      'Content-Type': contentType,
      'Content-Length': data.length,
      'Cross-Origin-Opener-Policy': 'same-origin',
      'Cross-Origin-Embedder-Policy': 'require-corp',
      'Cache-Control': ext === '.wasm'
        ? 'public, max-age=31536000, immutable'
        : 'public, max-age=86400',
    };

    if (compressed === 'gzip') headers['Content-Encoding'] = 'gzip';
    if (compressed === 'br')   headers['Content-Encoding'] = 'br';

    res.writeHead(200, headers);
    res.end(data);
  });
}

// --------------- Start server -------------------------------------------------
const server = http.createServer(serve);

server.listen(PORT, HOST, () => {
  console.log(`[flora64] serving ${ROOT}`);
  console.log(`[flora64] listening on http://${HOST}:${PORT}`);
});
