'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const receipts = [];
let databaseFails = false;
class FakePrisma {
  async $queryRawUnsafe(...args) {
    if (databaseFails) throw Object.assign(new Error('fixture'), { code: 'PTEST' });
    receipts.push({ node: String(args[1]), succeeded: args[3], users: JSON.parse(args[4]) });
    return [];
  }
}
const moduleValue = { exports: {} };
vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../stats/panel-hook.cjs'), 'utf8'), {
  exports: moduleValue.exports, module: moduleValue,
  require(name) { return name === '/opt/app/node_modules/@prisma/client' ? { PrismaClient: FakePrisma } : require(name); },
  process: { env: { DATABASE_URL: 'postgresql://fixture:fixture@localhost/fixture' } },
  URL, console: { error() {} },
});
const wrap = moduleValue.exports.wrapProcess;

(async () => {
  let calls = 0;
  const axios = { async getUsersStats(request) {
    calls++;
    assert.equal(request.reset, true);
    await new Promise(resolve => setTimeout(resolve, request.wanted === '7' ? 15 : 1));
    return { isOk: true, response: { users: [{ username: request.wanted, downlink: 5, uplink: 0 }] } };
  } };
  const first = { axios, ignoreBelowBytes: 10n };
  const second = { axios, ignoreBelowBytes: 0n };
  const job = node => ({ data: { nodeId: node, nodeUuid: '00000000-0000-4000-8000-00000000000' + node } });
  await Promise.all([
    wrap(first, job(1), () => axios.getUsersStats({ reset: true, wanted: '7' })),
    wrap(second, job(2), () => axios.getUsersStats({ reset: true, wanted: '8' })),
  ]);
  assert.equal(calls, 2);
  assert.deepEqual(receipts.find(item => item.node === '1').users, []);
  assert.deepEqual(receipts.find(item => item.node === '2').users, [{ user_id: '8', bytes: '5' }]);
  assert.ok(receipts.every(item => item.succeeded));
  databaseFails = true;
  const response = await wrap(second, job(2), () => axios.getUsersStats({ reset: true, wanted: '8' }));
  assert.equal(response.isOk, true);
  assert.equal(calls, 3);
  databaseFails = false;
  const broken = { axios: { async getUsersStats() { calls++; throw new Error('network'); } }, ignoreBelowBytes: 0n };
  await assert.rejects(wrap(broken, job(3), () => broken.axios.getUsersStats({ reset: true })), /network/);
  assert.equal(calls, 4);
  assert.equal(receipts.at(-1).succeeded, false);
  console.log('Hook context isolation, one native query, byte threshold, observer failure isolation and failed-sample witness passed.');
})().catch(error => { console.error(error); process.exitCode = 1; });
