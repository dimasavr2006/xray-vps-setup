'use strict';
const http = require('node:http');
const crypto = require('node:crypto');
const fs = require('node:fs');
const { PrismaClient } = require('/opt/app/node_modules/@prisma/client');
const token = fs.readFileSync(process.env.PDM_STATS_TOKEN_FILE, 'utf8').trim();
if (!/^[a-f0-9]{64}$/.test(token)) throw new Error('Invalid stats token file');
const db = new PrismaClient({ datasources: { db: { url: process.env.DATABASE_URL } }, log: [] });
const expected = Buffer.from('Bearer ' + token);

function moment(value) {
  const match = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.(\d{1,6}))?(?:Z|[+-]\d{2}:\d{2})$/.exec(value || '');
  if (!match) return null;
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) return null;
  // Keep PostgreSQL's microsecond precision; JavaScript Date is used only for validation.
  return { text: value, micros: BigInt(Math.floor(parsed.getTime() / 1000)) * 1000000n +
           BigInt((match[1] || '').padEnd(6, '0') || '0') };
}

function send(response, code, value) {
  response.writeHead(code, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
  response.end(JSON.stringify(value));
}

const server = http.createServer(async (request, response) => {
  const received = Buffer.from(request.headers.authorization || '');
  if (received.length !== expected.length || !crypto.timingSafeEqual(received, expected)) {
    send(response, 401, { error: 'unauthorized' }); return;
  }
  if (request.method !== 'GET') { send(response, 405, { error: 'method' }); return; }
  try {
    const url = new URL(request.url, 'http://stats.internal');
    if (url.pathname === '/health') {
      const result = await db.$queryRawUnsafe('SELECT pdm_stats.status() AS result');
      send(response, 200, result[0].result); return;
    }
    const match = /^\/v1\/users\/([1-9][0-9]{0,17})\/usage$/.exec(url.pathname);
    if (!match) { send(response, 404, { error: 'path' }); return; }
    const start = moment(url.searchParams.get('start'));
    const end = moment(url.searchParams.get('end'));
    if (!start || !end || start.micros > end.micros || end.micros > BigInt(Date.now() + 5000) * 1000n) {
      send(response, 400, { error: 'interval' }); return;
    }
    const result = await db.$queryRawUnsafe('SELECT pdm_stats.usage($1::bigint,$2::timestamptz,$3::timestamptz) AS result',
                                           BigInt(match[1]), start.text, end.text);
    send(response, 200, result[0].result);
  } catch (error) {
    console.error('PDM_STATS_API_ERROR', typeof error?.code === 'string' ? error.code : 'database');
    send(response, 503, { error: 'unavailable' });
  }
});
server.headersTimeout = 10000;
server.requestTimeout = 10000;
server.maxConnections = 32;
server.listen(Number(process.env.PDM_STATS_PORT || 13100), '0.0.0.0');
async function stop() { server.close(); await db.$disconnect(); }
process.on('SIGTERM', stop);
process.on('SIGINT', stop);
