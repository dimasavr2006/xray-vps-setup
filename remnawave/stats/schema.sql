-- Remnawave 3.4.5 addon, schema version 1. All times are observations in UTC.
-- No foreign keys point to panel history: retention cannot erase our evidence.
BEGIN;
DO $$
BEGIN
  IF (SELECT array_agg(column_name||':'||data_type ORDER BY ordinal_position)
      FROM information_schema.columns WHERE table_schema='public' AND table_name='nodes_user_usage_history')
     IS DISTINCT FROM ARRAY['node_id:bigint','user_id:bigint','total_bytes:bigint',
                            'created_at:date','updated_at:timestamp without time zone'] THEN
    RAISE EXCEPTION 'Unsupported nodes_user_usage_history schema';
  END IF;
END $$;
CREATE SCHEMA IF NOT EXISTS pdm_stats;
CREATE TABLE IF NOT EXISTS pdm_stats.metadata (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  version integer NOT NULL CHECK (version=1), installed_at timestamptz NOT NULL,
  panel_digest text NOT NULL, max_sample_gap_seconds integer NOT NULL DEFAULT 90
);
INSERT INTO pdm_stats.metadata(singleton,version,installed_at,panel_digest)
VALUES (true,1,clock_timestamp(),'b16d724b90fd7c9fec2df04bd28938a671cafc62894105068e11550ee3449c56')
ON CONFLICT DO NOTHING;
CREATE TABLE IF NOT EXISTS pdm_stats.node_state (
  node_id bigint PRIMARY KEY, node_uuid uuid NOT NULL, first_sample_at timestamptz,
  last_sample_at timestamptz, last_sample_succeeded boolean NOT NULL DEFAULT false
);
CREATE TABLE IF NOT EXISTS pdm_stats.samples (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  node_id bigint NOT NULL, node_uuid uuid NOT NULL,
  observed_at timestamptz NOT NULL, previous_at timestamptz,
  succeeded boolean NOT NULL, policy_ignore_below_bytes bigint NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS samples_node_time ON pdm_stats.samples(node_id,observed_at);
CREATE TABLE IF NOT EXISTS pdm_stats.expected (
  sample_id bigint NOT NULL REFERENCES pdm_stats.samples(id), node_id bigint NOT NULL,
  user_id bigint NOT NULL, remaining_bytes bigint NOT NULL CHECK (remaining_bytes>=0),
  invalidated boolean NOT NULL DEFAULT false,
  PRIMARY KEY(sample_id,user_id)
);
ALTER TABLE pdm_stats.expected ADD COLUMN IF NOT EXISTS invalidated boolean NOT NULL DEFAULT false;
DROP INDEX IF EXISTS pdm_stats.expected_pending;
CREATE INDEX IF NOT EXISTS expected_pending ON pdm_stats.expected(node_id,user_id,sample_id)
WHERE remaining_bytes>0 AND NOT invalidated;
CREATE TABLE IF NOT EXISTS pdm_stats.counter_state (
  node_id bigint NOT NULL, user_id bigint NOT NULL, source_day date NOT NULL,
  node_uuid uuid NOT NULL, total_bytes bigint NOT NULL,
  epoch bigint NOT NULL DEFAULT 0, last_observed_at timestamptz NOT NULL,
  deleted boolean NOT NULL DEFAULT false,
  PRIMARY KEY(node_id,user_id,source_day)
);
CREATE TABLE IF NOT EXISTS pdm_stats.events (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  node_id bigint NOT NULL, node_uuid uuid NOT NULL, user_id bigint NOT NULL,
  observed_at timestamptz NOT NULL, source_day date NOT NULL, epoch bigint NOT NULL,
  delta_bytes bigint NOT NULL CHECK(delta_bytes>=0)
);
CREATE INDEX IF NOT EXISTS events_user_time ON pdm_stats.events(user_id,observed_at);
CREATE TABLE IF NOT EXISTS pdm_stats.gaps (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  node_id bigint NOT NULL, user_id bigint,
  start_at timestamptz NOT NULL, end_at timestamptz NOT NULL,
  reason text NOT NULL, CHECK(end_at>=start_at)
);
CREATE INDEX IF NOT EXISTS gaps_user_time ON pdm_stats.gaps(user_id,start_at,end_at);
CREATE TABLE IF NOT EXISTS pdm_stats.hours (
  node_uuid uuid NOT NULL, node_id bigint NOT NULL, user_id bigint NOT NULL,
  hour_at timestamptz NOT NULL, total_bytes bigint NOT NULL CHECK(total_bytes>=0),
  raw_preserved boolean NOT NULL, PRIMARY KEY(node_uuid,user_id,hour_at)
);
CREATE TABLE IF NOT EXISTS pdm_stats.checkpoints (
  name text PRIMARY KEY, observed_at timestamptz NOT NULL
);

-- Initialize current panel counters as a baseline; do not fabricate old observations.
INSERT INTO pdm_stats.counter_state(node_id,user_id,source_day,node_uuid,total_bytes,last_observed_at)
SELECT h.node_id,h.user_id,h.created_at,n.uuid,h.total_bytes,clock_timestamp()
FROM public.nodes_user_usage_history h JOIN public.nodes n ON n.id=h.node_id
ON CONFLICT DO NOTHING;

CREATE OR REPLACE FUNCTION pdm_stats.observe_sample(
  p_node_id bigint,p_uuid uuid,p_succeeded boolean,p_users jsonb,p_threshold bigint DEFAULT 0)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path=pdm_stats,pg_catalog AS $$
DECLARE previous timestamptz; observed timestamptz:=clock_timestamp(); sid bigint; item jsonb;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM public.nodes WHERE id=p_node_id AND uuid=p_uuid)
     OR jsonb_typeof(p_users)<>'array' OR p_threshold<0 THEN
    RAISE EXCEPTION 'Invalid sample node or payload';
  END IF;
  INSERT INTO pdm_stats.node_state(node_id,node_uuid) VALUES(p_node_id,p_uuid) ON CONFLICT DO NOTHING;
  SELECT last_sample_at INTO previous FROM pdm_stats.node_state WHERE node_id=p_node_id FOR UPDATE;
  INSERT INTO pdm_stats.samples(node_id,node_uuid,observed_at,previous_at,succeeded,policy_ignore_below_bytes)
  VALUES(p_node_id,p_uuid,observed,previous,p_succeeded,p_threshold) RETURNING id INTO sid;
  IF p_succeeded THEN
    FOR item IN SELECT value FROM jsonb_array_elements(p_users) LOOP
      IF (item->>'user_id') !~ '^[1-9][0-9]*$' OR (item->>'bytes') !~ '^(0|[1-9][0-9]*)$' THEN
        RAISE EXCEPTION 'Invalid sample counter';
      END IF;
      INSERT INTO pdm_stats.expected(sample_id,node_id,user_id,remaining_bytes)
      VALUES(sid,p_node_id,(item->>'user_id')::bigint,(item->>'bytes')::bigint);
    END LOOP;
  END IF;
  IF previous IS NOT NULL AND (NOT p_succeeded OR observed-previous>
      (SELECT max_sample_gap_seconds*interval '1 second' FROM pdm_stats.metadata)) THEN
    INSERT INTO pdm_stats.gaps(node_id,start_at,end_at,reason)
    VALUES(p_node_id,previous,observed,CASE WHEN p_succeeded THEN 'sample_gap' ELSE 'sample_failed' END);
  END IF;
  UPDATE pdm_stats.node_state SET last_sample_at=observed,
    last_sample_succeeded=p_succeeded,
    first_sample_at=CASE WHEN p_succeeded THEN coalesce(first_sample_at,observed) ELSE first_sample_at END
  WHERE node_id=p_node_id;
  RETURN sid;
END $$;

CREATE OR REPLACE FUNCTION pdm_stats.capture_history()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pdm_stats,pg_catalog AS $$
DECLARE state pdm_stats.counter_state%ROWTYPE; observed timestamptz:=clock_timestamp();
        delta bigint:=0; next_epoch bigint:=0; remaining bigint; allocated bigint;
        expected_row record; node_uuid_value uuid; why text;
BEGIN
  IF TG_OP='DELETE' THEN
    UPDATE pdm_stats.counter_state SET deleted=true
    WHERE node_id=OLD.node_id AND user_id=OLD.user_id AND source_day=OLD.created_at;
    RETURN OLD;
  END IF;
  SELECT * INTO state FROM pdm_stats.counter_state
  WHERE node_id=NEW.node_id AND user_id=NEW.user_id AND source_day=NEW.created_at FOR UPDATE;
  SELECT uuid INTO node_uuid_value FROM public.nodes WHERE id=NEW.node_id;
  IF node_uuid_value IS NULL THEN RAISE EXCEPTION 'History node missing'; END IF;
  IF state.node_id IS NULL THEN
    delta:=NEW.total_bytes;
  ELSIF (TG_OP='INSERT' AND state.deleted) OR NEW.total_bytes<state.total_bytes THEN
    next_epoch:=state.epoch+1;
    why:=CASE WHEN TG_OP='INSERT' THEN 'row_recreated' ELSE 'counter_decreased' END;
  ELSE
    next_epoch:=state.epoch;
    delta:=NEW.total_bytes-state.total_bytes;
  END IF;
  IF delta<0 THEN RAISE EXCEPTION 'Negative history delta'; END IF;
  IF why IS NOT NULL THEN
    INSERT INTO pdm_stats.gaps(node_id,user_id,start_at,end_at,reason)
    VALUES(NEW.node_id,NEW.user_id,state.last_observed_at,observed,why);
    UPDATE pdm_stats.expected SET invalidated=true
    WHERE node_id=NEW.node_id AND user_id=NEW.user_id AND remaining_bytes>0;
  END IF;
  INSERT INTO pdm_stats.counter_state(node_id,user_id,source_day,node_uuid,total_bytes,epoch,last_observed_at)
  VALUES(NEW.node_id,NEW.user_id,NEW.created_at,node_uuid_value,NEW.total_bytes,next_epoch,observed)
  ON CONFLICT(node_id,user_id,source_day) DO UPDATE SET total_bytes=EXCLUDED.total_bytes,
    epoch=EXCLUDED.epoch,last_observed_at=EXCLUDED.last_observed_at,deleted=false;
  IF delta>0 THEN
    remaining:=delta;
    FOR expected_row IN SELECT ex.*,sm.observed_at AS sample_observed_at FROM pdm_stats.expected ex
      JOIN pdm_stats.samples sm ON sm.id=ex.sample_id
      WHERE ex.node_id=NEW.node_id AND ex.user_id=NEW.user_id AND ex.remaining_bytes>0 AND NOT ex.invalidated
      ORDER BY ex.sample_id FOR UPDATE OF ex LOOP
      allocated:=least(remaining,expected_row.remaining_bytes);
      INSERT INTO pdm_stats.events(node_id,node_uuid,user_id,observed_at,source_day,epoch,delta_bytes)
      VALUES(NEW.node_id,node_uuid_value,NEW.user_id,expected_row.sample_observed_at,NEW.created_at,next_epoch,allocated);
      UPDATE pdm_stats.hours SET total_bytes=total_bytes+allocated
      WHERE node_uuid=node_uuid_value AND user_id=NEW.user_id
        AND hour_at=date_trunc('hour',expected_row.sample_observed_at AT TIME ZONE 'UTC') AT TIME ZONE 'UTC';
      UPDATE pdm_stats.expected SET remaining_bytes=remaining_bytes-allocated
      WHERE sample_id=expected_row.sample_id AND user_id=NEW.user_id;
      remaining:=remaining-allocated;
      EXIT WHEN remaining=0;
    END LOOP;
    IF remaining>0 THEN
      INSERT INTO pdm_stats.events(node_id,node_uuid,user_id,observed_at,source_day,epoch,delta_bytes)
      VALUES(NEW.node_id,node_uuid_value,NEW.user_id,observed,NEW.created_at,next_epoch,remaining);
      INSERT INTO pdm_stats.gaps(node_id,user_id,start_at,end_at,reason)
      VALUES(NEW.node_id,NEW.user_id,coalesce(state.last_observed_at,
        (SELECT installed_at FROM pdm_stats.metadata)),observed,'unwitnessed_delta');
    END IF;
  END IF;
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  -- An addon failure cannot roll back the panel's authoritative traffic write.
  RAISE WARNING 'PDM_STATS_CAPTURE_FAILED: %', SQLSTATE;
  BEGIN
    INSERT INTO pdm_stats.gaps(node_id,user_id,start_at,end_at,reason)
    VALUES(coalesce(NEW.node_id,OLD.node_id),coalesce(NEW.user_id,OLD.user_id),
      coalesce(state.last_observed_at,observed),observed,'capture_error');
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
  RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
END $$;
DROP TRIGGER IF EXISTS pdm_stats_history ON public.nodes_user_usage_history;
CREATE TRIGGER pdm_stats_history AFTER INSERT OR UPDATE OR DELETE ON public.nodes_user_usage_history
FOR EACH ROW EXECUTE FUNCTION pdm_stats.capture_history();

CREATE OR REPLACE FUNCTION pdm_stats.add_checkpoint(p_name text,p_at timestamptz)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pdm_stats,pg_catalog AS $$
BEGIN
  IF EXISTS(SELECT 1 FROM pdm_stats.hours WHERE hour_at=date_trunc('hour',p_at AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'
            AND NOT raw_preserved) THEN RAISE EXCEPTION 'Checkpoint hour was already compacted'; END IF;
  INSERT INTO pdm_stats.checkpoints VALUES(p_name,p_at) ON CONFLICT DO NOTHING;
  IF EXISTS(SELECT 1 FROM pdm_stats.checkpoints WHERE name=p_name AND observed_at<>p_at) THEN
    RAISE EXCEPTION 'Checkpoint is immutable'; END IF;
END $$;

CREATE OR REPLACE FUNCTION pdm_stats.compact(p_before timestamptz)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path=pdm_stats,pg_catalog AS $$
DECLARE removed bigint;
BEGIN
  IF p_before>date_trunc('hour',(clock_timestamp()-interval '48 hours') AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'
    THEN RAISE EXCEPTION 'Only closed observations older than 48h may be compacted'; END IF;
  WITH grouped AS (
    SELECT e.node_uuid,e.node_id,e.user_id,
      date_trunc('hour',e.observed_at AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' AS hour_at,sum(e.delta_bytes) AS bytes
    FROM pdm_stats.events e WHERE e.observed_at<p_before
      AND NOT EXISTS(SELECT 1 FROM pdm_stats.hours h WHERE h.node_uuid=e.node_uuid AND h.user_id=e.user_id
        AND h.hour_at=date_trunc('hour',e.observed_at AT TIME ZONE 'UTC') AT TIME ZONE 'UTC')
    GROUP BY e.node_uuid,e.node_id,e.user_id,date_trunc('hour',e.observed_at AT TIME ZONE 'UTC')
  )
  INSERT INTO pdm_stats.hours(node_uuid,node_id,user_id,hour_at,total_bytes,raw_preserved)
  SELECT g.node_uuid,g.node_id,g.user_id,g.hour_at,g.bytes,
    EXISTS(SELECT 1 FROM pdm_stats.checkpoints c WHERE
      date_trunc('hour',c.observed_at AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'=g.hour_at)
  FROM grouped g
  ON CONFLICT DO NOTHING;
  DELETE FROM pdm_stats.events e USING pdm_stats.hours h
  WHERE e.node_uuid=h.node_uuid AND e.user_id=h.user_id AND e.observed_at>=h.hour_at
    AND e.observed_at<h.hour_at+interval '1 hour' AND NOT h.raw_preserved;
  GET DIAGNOSTICS removed=ROW_COUNT;
  RETURN removed;
END $$;

CREATE OR REPLACE FUNCTION pdm_stats.status()
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path=pdm_stats,pg_catalog AS $$
SELECT jsonb_build_object('schema_version',version,'installed_at',installed_at,
                         'panel_digest',panel_digest,'observed_at',clock_timestamp()) FROM pdm_stats.metadata
$$;

CREATE OR REPLACE FUNCTION pdm_stats.usage(p_user bigint,p_start timestamptz,p_end timestamptz)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pdm_stats,pg_catalog AS $$
DECLARE result jsonb; observed timestamptz:=clock_timestamp(); born timestamptz;
        effective_start timestamptz; maximum_gap interval;
BEGIN
  IF p_user<=0 OR p_start>p_end OR p_end>observed+interval '5 seconds' THEN
    RAISE EXCEPTION 'Invalid user or observation interval'; END IF;
  SELECT created_at AT TIME ZONE 'UTC' INTO born FROM public.users WHERE id=p_user;
  effective_start:=greatest(p_start,coalesce(born,p_start));
  SELECT max_sample_gap_seconds*interval '1 second' INTO maximum_gap FROM pdm_stats.metadata;
  WITH totals AS (
    SELECT node_id,node_uuid,sum(delta_bytes)::bigint AS bytes FROM pdm_stats.events e
    WHERE user_id=p_user AND observed_at>=p_start AND observed_at<p_end
      AND NOT EXISTS(SELECT 1 FROM pdm_stats.hours h WHERE h.node_uuid=e.node_uuid
        AND h.user_id=e.user_id AND h.hour_at<=e.observed_at AND e.observed_at<h.hour_at+interval '1 hour'
        AND h.hour_at>=p_start AND h.hour_at+interval '1 hour'<=p_end)
    GROUP BY node_id,node_uuid
    UNION ALL
    SELECT node_id,node_uuid,total_bytes FROM pdm_stats.hours
    WHERE user_id=p_user AND hour_at>=p_start AND hour_at+interval '1 hour'<=p_end
  ), amounts AS (
    SELECT node_id,node_uuid,sum(bytes)::bigint AS bytes FROM totals GROUP BY node_id,node_uuid
  ), scope AS (
    SELECT id AS node_id,uuid AS node_uuid FROM public.nodes
    UNION SELECT node_id,node_uuid FROM amounts
  ), coverage AS (
    SELECT s.node_id,s.node_uuid,
      coalesce((effective_start>=p_end AND NOT EXISTS(SELECT 1 FROM amounts a WHERE a.node_id=s.node_id AND a.bytes>0)) OR (
        effective_start<p_end AND
        st.first_sample_at<=effective_start AND st.last_sample_at>=p_end-maximum_gap
        AND (st.last_sample_at>=p_end OR st.last_sample_succeeded)
        AND NOT EXISTS(SELECT 1 FROM pdm_stats.gaps g WHERE g.node_id=s.node_id
          AND (g.user_id IS NULL OR g.user_id=p_user) AND g.start_at<p_end AND g.end_at>=effective_start)
        AND NOT EXISTS(SELECT 1 FROM pdm_stats.expected ex JOIN pdm_stats.samples sm ON sm.id=ex.sample_id
          WHERE ex.node_id=s.node_id AND ex.user_id=p_user AND ex.remaining_bytes>0 AND NOT ex.invalidated
            AND sm.observed_at>=effective_start AND sm.observed_at<p_end)
        AND NOT EXISTS(SELECT 1 FROM pdm_stats.hours h WHERE h.node_id=s.node_id AND h.user_id=p_user
          AND NOT raw_preserved AND h.hour_at<p_end AND h.hour_at+interval '1 hour'>p_start
          AND NOT (h.hour_at>=p_start AND h.hour_at+interval '1 hour'<=p_end))
      ),false) AS complete, st.last_sample_at AS measured_until
    FROM scope s LEFT JOIN pdm_stats.node_state st USING(node_id)
  ), summary AS (
    SELECT coalesce(bool_and(complete),false) AS complete, min(measured_until) AS measured_until FROM coverage
  )
  SELECT jsonb_build_object('schema_version',1,'user_id',p_user,'start',p_start,'end',p_end,
    'observed_at',observed,'measured_until',(SELECT measured_until FROM summary),
    'precision','Panel-accounted bytes at database observation time; normal sample lag is explicit',
    'nodes',coalesce((SELECT jsonb_agg(jsonb_build_object('node_uuid',node_uuid,'bytes',bytes::text)
      ORDER BY node_uuid) FROM amounts),'[]'::jsonb),
    'covered_node_uuids',coalesce((SELECT jsonb_agg(node_uuid ORDER BY node_uuid) FROM coverage WHERE complete),'[]'::jsonb),
    'complete',(SELECT complete FROM summary),'unknown_bytes','0','unknown_bytes_are_quantified',(SELECT complete FROM summary),
    'known_bytes',coalesce((SELECT sum(bytes) FROM amounts),0)::text,
    'total_bytes',CASE WHEN (SELECT complete FROM summary) THEN
      coalesce((SELECT sum(bytes) FROM amounts),0)::text ELSE NULL END,
    'coverage',coalesce((SELECT jsonb_agg(jsonb_build_object('node_uuid',node_uuid,'complete',complete,
      'measured_until',measured_until) ORDER BY node_uuid) FROM coverage),'[]'::jsonb)) INTO result;
  RETURN result;
END $$;
REVOKE ALL ON SCHEMA pdm_stats FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pdm_stats FROM PUBLIC;
COMMIT;
