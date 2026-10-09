"""Real PostgreSQL/HTTP tests on the disposable Debian panel, including failure paths."""
from __future__ import annotations

import asyncio
import json
import subprocess
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

from vpn_bot.models import NodeCode, UserExpireStrategy
from vpn_bot.remnawave import RemnawaveGateway
from vpn_bot.storage import SQLiteStore

workspace = Path(__file__).resolve().parents[2]
private = workspace / "private-backups/remnawave-ci-20261009"
token = (private / "stats-api.token").read_text().strip()
checks: list[str] = []


def sql(statement: str, *, fails: bool = False) -> str:
    result = subprocess.run([
        "wsl.exe", "-d", "PDM-RW-Debian13", "-u", "root", "--", "docker", "exec", "-i",
        "pdm-rw-ci-panel-rw_db-1", "psql", "-qAt", "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", "remnawave",
    ], input=statement, text=True, capture_output=True, check=False)
    if fails:
        assert result.returncode != 0, "Read-only role unexpectedly succeeded"
    elif result.returncode:
        raise AssertionError(result.stderr)
    return result.stdout.strip()


def api(user_id: int, start: datetime, end: datetime, *, authorized: bool = True) -> dict:
    query = urlencode({"start": start.isoformat(), "end": end.isoformat()})
    headers = {"Authorization": "Bearer " + token} if authorized else {}
    with urlopen(Request(f"http://127.0.0.1:13100/v1/users/{user_id}/usage?{query}", headers=headers), timeout=10) as response:
        return json.load(response)


async def main() -> None:
    store = SQLiteStore(private / "stats-state.sqlite3", "native-stats-ci")
    store.initialize()
    gateway = RemnawaveGateway("http://127.0.0.1:13300", private / "bot-api.token", store, {},
                               stats_base_url="http://127.0.0.1:13100", stats_token_file=private / "stats-api.token")
    node = (await gateway.list_nodes())[0]
    gateway.set_node_binding(node.id, NodeCode.FI)
    user = await gateway.create_user("ci-stat-contract", expire_strategy=UserExpireStrategy.NEVER)
    uid = user.id
    node_uuid = store.external_entity_id("node", node.id)
    assert node_uuid is not None
    nid = int(sql(f"SELECT id FROM public.nodes WHERE uuid='{node_uuid}';"))
    for _ in range(60):
        healthy = sql(f"SELECT coalesce(bool_and(last_sample_succeeded AND "
                      f"last_sample_at>clock_timestamp()-interval '20 seconds'),false) "
                      f"FROM pdm_stats.node_state WHERE node_id={nid};")
        if healthy == "t":
            break
        await asyncio.sleep(1)
    assert healthy == "t", "Native sampler did not produce a fresh successful witness"
    (private / "stats-live-cleanup.json").write_text(json.dumps({"user_id": uid, "username": user.username}), encoding="utf-8")
    source_day = "(now() AT TIME ZONE 'UTC')::date"
    history = f"public.nodes_user_usage_history"
    # Repeated test runs clear only this proven, locally owned synthetic account's fixtures.
    sql(f"DELETE FROM {history} WHERE user_id={uid}; "
        f"DELETE FROM pdm_stats.counter_state WHERE user_id={uid}; "
        f"DELETE FROM pdm_stats.expected WHERE user_id={uid}; "
        f"DELETE FROM pdm_stats.events WHERE user_id={uid}; "
        f"DELETE FROM pdm_stats.hours WHERE user_id={uid}; "
        f"DELETE FROM pdm_stats.gaps WHERE user_id={uid};")

    def witness(amount: int) -> str:
        body = json.dumps([{"user_id": str(uid), "bytes": str(amount)}])
        return f"SELECT pdm_stats.observe_sample({nid},'{node_uuid}',true,'{body}'::jsonb);"

    def upsert(amount: int) -> str:
        return (f"INSERT INTO {history}(node_id,user_id,total_bytes,created_at,updated_at) "
                f"VALUES({nid},{uid},{amount},{source_day},now()) ON CONFLICT(node_id,created_at,user_id) "
                f"DO UPDATE SET total_bytes={history}.total_bytes+EXCLUDED.total_bytes,updated_at=now();")

    def observed() -> int:
        return int(sql(f"SELECT coalesce(sum(delta_bytes),0) FROM pdm_stats.events WHERE user_id={uid};"))

    start = datetime.now(timezone.utc) - timedelta(milliseconds=1)
    sql(witness(100) + upsert(100))
    assert observed() == 100
    sql(witness(25) + upsert(25))
    assert observed() == 125
    checks.append("INSERT/UPSERT count positive deltas once")
    sql("BEGIN;" + witness(999) + upsert(999) + "ROLLBACK;")
    assert observed() == 125
    checks.append("transaction rollback removes observations and expected samples")
    partial = api(uid, start, datetime.now(timezone.utc))
    assert partial["complete"] is True and partial["known_bytes"] == "125"
    snapshot = await gateway.get_user_node_usage_snapshot(user.username, start, datetime.now(timezone.utc))
    assert snapshot.value_for(NodeCode.FI) == 125 and snapshot.total_bytes == 125
    checks.append("live read-only API and gateway agree, preserving microsecond bounds")

    sql(witness(50) + "ALTER TABLE pdm_stats.events RENAME TO events_disabled_fixture;" + upsert(50) +
        "ALTER TABLE pdm_stats.events_disabled_fixture RENAME TO events;")
    assert int(sql(f"SELECT total_bytes FROM {history} WHERE node_id={nid} AND user_id={uid} AND created_at={source_day};")) == 175
    assert observed() == 125
    assert not api(uid, start, datetime.now(timezone.utc))["complete"]
    sql(witness(25) + upsert(25))
    assert observed() == 200
    checks.append("addon failure leaves authoritative panel write intact and marks incomplete")

    sql(f"UPDATE {history} SET total_bytes=0 WHERE node_id={nid} AND user_id={uid} AND created_at={source_day};")
    assert observed() == 200
    sql(witness(10) + upsert(10))
    assert observed() == 210
    sql(f"DELETE FROM {history} WHERE node_id={nid} AND user_id={uid} AND created_at={source_day};" + upsert(10))
    assert observed() == 210
    assert not api(uid, start, datetime.now(timezone.utc))["complete"]
    checks.append("counter decrease/recreation advances epochs without negative or duplicate bytes")
    sql(f"SELECT pdm_stats.observe_sample({nid},'{node_uuid}',false,'[]');")
    assert not api(uid, start, datetime.now(timezone.utc))["complete"]
    checks.append("failed sample is not a confirmed zero")

    sql("SET ROLE pdm_stats_api; SELECT username FROM public.users LIMIT 1;", fails=True)
    sql("SET ROLE pdm_stats_api; INSERT INTO pdm_stats.metadata VALUES(true,1,now(),'x',90);", fails=True)
    sql(f"SET ROLE pdm_stats_api; SELECT pdm_stats.observe_sample({nid},'{node_uuid}',true,'[]');", fails=True)
    checks.append("API role cannot read panel tables, write addon tables or forge samples")
    try:
        api(uid, start, datetime.now(timezone.utc), authorized=False)
        raise AssertionError("unauthorized stats accepted")
    except HTTPError as error:
        assert error.code == 401
    checks.append("HTTP API requires its separate token")

    # Replace only this synthetic fixture's ledger for exact Moscow/checkpoint tests.
    sql(f"DELETE FROM pdm_stats.events WHERE user_id={uid}; DELETE FROM pdm_stats.hours WHERE user_id={uid};")
    boundary = datetime(2026, 9, 30, 21, tzinfo=timezone.utc)
    checkpoint = boundary + timedelta(minutes=13, seconds=14, microseconds=123456)
    fixtures = [(boundary - timedelta(microseconds=1), 3), (boundary, 5),
                (checkpoint - timedelta(microseconds=1), 7), (checkpoint, 11)]
    for moment, amount in fixtures:
        sql(f"INSERT INTO pdm_stats.events(node_id,node_uuid,user_id,observed_at,source_day,epoch,delta_bytes) "
            f"VALUES({nid},'{node_uuid}',{uid},'{moment.isoformat()}','2026-09-30',0,{amount});")
    raw = api(uid, boundary, boundary + timedelta(hours=1))
    assert raw["known_bytes"] == "23"
    assert api(uid, checkpoint, boundary + timedelta(hours=1))["known_bytes"] == "11"
    sql(f"SELECT pdm_stats.add_checkpoint('ci-exact-{uid}','{checkpoint.isoformat()}');")
    sql("SELECT pdm_stats.compact('2026-10-01T00:00:00Z');")
    assert api(uid, boundary, boundary + timedelta(hours=1))["known_bytes"] == "23"
    assert api(uid, checkpoint, boundary + timedelta(hours=1))["known_bytes"] == "11"
    assert observed() == 23  # checkpoint hour's raw events survive; previous hour compacted
    checks.append("Moscow 21:00 UTC boundary and arbitrary microsecond checkpoint survive compaction")
    report = {"date": "2026-10-09", "host": "disposable Debian 13 native Docker",
              "checks": checks, "result": "pass", "production_mutated": False,
              "additional_xray_poller": False}
    (Path(__file__).parent / "verification.stats.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    asyncio.run(main())
