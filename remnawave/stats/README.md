# Interval usage accounting

Optional pilot addon for the pinned Panel 3.4.5 image. It uses the panel's
existing collector and a separate PostgreSQL schema, `pdm_stats`. It creates
no additional Xray poller and does not reset Xray counters.

`schema.sql` records positive deltas from applied INSERT/UPDATE operations.
UPSERT is counted once and transaction rollback removes the journal entry.
Counter decreases and recreated rows begin a new epoch and mark uncertainty.
Panel history cleanup does not delete the addon's own observations. Addon
failure keeps the authoritative panel write and marks the interval incomplete.

The panel collector does not write a row for a successful empty sample.
`panel-hook.cjs` witnesses the existing `getUsersStats` result and expected
bytes with AsyncLocalStorage isolation. `patch-panel.cjs` accepts only the
verified processor bundle SHA256:

```text
3c746587906be64386f673bb313a5813e4cab8283de1c847bf97187813fdb62e
```

Unexpected code stops installation. A changed panel image requires a new
compatibility check before upgrading a panel with this addon.

Deltas reconcile against expected samples in FIFO order. Their timestamp is
the sample's first arrival, with PostgreSQL microsecond precision. A queued
write therefore does not cross a Moscow month boundary solely because of
queue delay. Semantics are panel-accounted bytes, including its
`USER_USAGE_IGNORE_BELOW_BYTES` threshold; packet timestamps are unknown.
`measured_until` reports the last collector result. A gap over 90 seconds,
failed sample, unmatched expectation or uncertain epoch makes the affected
history incomplete.

UTC hours compact after 48 hours. Full hours can use buckets; partial intervals
require retained raw events. Immutable checkpoints protect their entire hour
without rounding the checkpoint boundary. A later checkpoint cannot recover
already discarded detail.

## Read-only API

`GET /v1/users/ID/usage?start=ISO&end=ISO` uses `[start,end)` and returns
per-node bytes, coverage, completeness and observation bounds. When incomplete,
`total_bytes=null`; `known_bytes` is a confirmed lower bound. A zero
`unknown_bytes` with `unknown_bytes_are_quantified=false` does not prove no
missing usage. History before the first confirmed sample remains unknown.

The loopback-only API requires its own token. Its PostgreSQL login can invoke
two read-only functions; it cannot read panel tables, write addon data or forge
samples. The container uses a read-only filesystem, drops capabilities and has
a 96 MiB limit. The bot receives HTTP access rather than database credentials.

```bash
bash /opt/pdm-remnawave/vpn-main/rwctl stats install --stats-port 13100 --dry-run
bash /opt/pdm-remnawave/vpn-main/rwctl stats install --stats-port 13100
bash /opt/pdm-remnawave/vpn-main/rwctl stats status
```

Installation creates a consistent backup and recovers the previous stack if
activation fails. Restore creates the read-only role before pg_restore and
regenerates trusted addon code. Backup/purge/restore, upgrade/rollback and port
conflict recovery were tested. In `compact-test`, total container limits become
1248 MiB and panel heap is 160 MiB with a 512 MiB hard limit.

See [verification.stats.json](../tests/verification.stats.json),
[stats-live.py](../tests/stats-live.py) and
[FI verification](../tests/verification.fi.json). This remains a pilot;
production personal limits require history/completeness acceptance first.
