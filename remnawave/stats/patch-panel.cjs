'use strict';
// Run inside the pinned official image, against its own extracted processor bundle.
const fs = require('node:fs');
const crypto = require('node:crypto');
const original = fs.readFileSync(process.argv[2]);
const expected = '3c746587906be64386f673bb313a5813e4cab8283de1c847bf97187813fdb62e';
if (crypto.createHash('sha256').update(original).digest('hex') !== expected) {
  throw new Error('Unsupported Remnawave processor bundle; no patch applied');
}
const source = original.toString('utf8');
const classStart = source.indexOf('function RecordUserUsageQueueProcessor(');
const methodStart = source.indexOf('{key:"process",value:function process(e){', classStart);
const methodEnd = source.indexOf('}},{key:"handleOk"', methodStart);
if (classStart < 0 || methodStart < classStart || methodEnd < methodStart) throw new Error('Worker shape changed');
const prefix = '{key:"process",value:function process(e){';
const body = source.slice(methodStart + prefix.length, methodEnd);
if (!body.startsWith('return ') || !body.endsWith('.call(this)')) throw new Error('Worker body changed');
const expression = body.slice('return '.length);
const replacement = prefix + 'return require("/opt/pdm-stats/panel-hook.cjs").wrapProcess(this,e,()=>(' + expression + '))';
const patched = source.slice(0, methodStart) + replacement + source.slice(methodEnd);
// Compile syntax without executing a server, accessing credentials or contacting Xray.
new (require('node:vm').Script)(patched);
fs.writeFileSync(process.argv[3], patched, { mode: 0o600 });
console.log('Patched one pinned worker process method; base SHA256 verified.');
