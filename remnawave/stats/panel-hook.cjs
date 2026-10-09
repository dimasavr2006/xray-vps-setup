'use strict';
// Observe the panel's existing getUsersStats call. No additional Xray query/reset occurs.
const { AsyncLocalStorage } = require('node:async_hooks');
const { PrismaClient } = require('/opt/app/node_modules/@prisma/client');
const scope = new AsyncLocalStorage();
const instrumented = Symbol.for('pdm.stats.getUsersStats.instrumented.v1');
let database;

function db() {
  if (!database) {
    const url = new URL(process.env.DATABASE_URL);
    url.searchParams.set('connection_limit', '1');
    url.searchParams.set('pool_timeout', '1');
    url.searchParams.set('connect_timeout', '2');
    url.searchParams.set('socket_timeout', '2');
    database = new PrismaClient({ datasources: { db: { url: url.toString() } }, log: [] });
  }
  return database;
}

async function witness(context, result) {
  context.observed = true;
  try {
    let success = result?.isOk === true;
    const expected = [];
    if (success) {
      if (!Array.isArray(result.response?.users)) throw new Error('invalid stats response');
      for (const user of result.response.users) {
        const total = user.downlink + user.uplink;
        // This matches the pinned worker's accepted numeric usernames and byte threshold.
        if (!/^[1-9][0-9]*$/.test(String(user.username))) continue;
        if (!Number.isSafeInteger(total) || total < 0) throw new Error('unsafe counter');
        if (BigInt(total) < BigInt(context.ignoreBelowBytes)) continue;
        expected.push({ user_id: String(user.username), bytes: String(total) });
      }
    }
    await db().$queryRawUnsafe(
      'SELECT pdm_stats.observe_sample($1::bigint,$2::uuid,$3::boolean,$4::jsonb,$5::bigint)',
      BigInt(context.nodeId), context.nodeUuid, success, JSON.stringify(expected),
      BigInt(context.ignoreBelowBytes),
    );
  } catch (error) {
    // Observation failure must not interrupt the panel after its counter read/reset.
    console.error('PDM_STATS_OBSERVATION_FAILED', typeof error?.code === 'string' ? error.code : 'observer');
  }
}

function instrument(instance) {
  const axios = instance.axios;
  if (axios[instrumented]) return;
  const original = axios.getUsersStats;
  if (typeof original !== 'function') throw new Error('unsupported worker');
  axios.getUsersStats = async function (...args) {
    const context = scope.getStore();
    try {
      const result = await original.apply(this, args);
      if (context) await witness(context, result);
      return result;
    } catch (error) {
      if (context) await witness(context, { isOk: false });
      throw error;
    }
  };
  axios[instrumented] = true;
}

exports.wrapProcess = function (instance, job, original) {
  try {
    instrument(instance);
  } catch {
    console.error('PDM_STATS_OBSERVATION_FAILED', 'instrumentation');
    return original();
  }
  const context = {
    nodeId: job.data.nodeId, nodeUuid: job.data.nodeUuid,
    ignoreBelowBytes: instance.ignoreBelowBytes ?? 0n, observed: false,
  };
  return scope.run(context, async () => {
    try {
      return await original();
    } finally {
      if (!context.observed) await witness(context, { isOk: false });
    }
  });
};
