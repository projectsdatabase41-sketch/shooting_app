-- Schema v2 (additive, idempotent): real links instead of conventions, value checks,
-- indexes, and a separate DEVICE LAYER (devices, shot_samples) that touches the training
-- tables only through shots.device_id / shot_samples.shot_id. Nothing is dropped or
-- renamed: existing data (training, notes, books, table_docs) stays as it is.
-- Run after the core schema (lib/db/puls_install.sql). Safe to run repeatedly.

-- ---------------------------------------------------------------------------
-- Device layer: what hardware produced the data
-- ---------------------------------------------------------------------------
create table if not exists devices (
  id           uuid primary key default gen_random_uuid(),
  kind         text not null default 'other',
  name         text not null,
  serial       text,
  firmware     text,
  calibration  jsonb,
  status       text not null default 'active',
  extra        jsonb,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
alter table devices drop constraint if exists devices_kind_check;
alter table devices add constraint devices_kind_check
  check (kind in ('argus', 'trigger', 'target_system', 'other'));
alter table devices drop constraint if exists devices_status_check;
alter table devices add constraint devices_status_check
  check (status in ('active', 'retired'));
create unique index if not exists uq_devices_serial on devices (kind, serial) where serial is not null;

-- ---------------------------------------------------------------------------
-- Exercises: a real link to the catalog and an explicit order inside the package
-- ---------------------------------------------------------------------------
alter table exercises add column if not exists template_id uuid references exercise_templates(id) on delete set null;
alter table exercises add column if not exists position int not null default 1;

update exercises
   set template_id = (extra->>'template_id')::uuid
 where template_id is null
   and extra->>'template_id' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
   and exists (select 1 from exercise_templates t where t.id = (extra->>'template_id')::uuid);

create unique index if not exists uq_exercises_package_position on exercises (package_id, position);
create index if not exists idx_exercises_template on exercises (template_id);
alter table exercises drop constraint if exists exercises_distance_check;
alter table exercises add constraint exercises_distance_check check (distance_meters > 0);

-- ---------------------------------------------------------------------------
-- Series: optional per-series record (time, note); shots.series_no stays the key
-- ---------------------------------------------------------------------------
create table if not exists series (
  id           uuid primary key default gen_random_uuid(),
  exercise_id  uuid not null references exercises(id) on delete cascade,
  series_no    int not null,
  started_at   timestamptz,
  ended_at     timestamptz,
  note         text,
  extra        jsonb,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (exercise_id, series_no)
);

-- ---------------------------------------------------------------------------
-- Shots: device link, absolute time, sane value ranges, query indexes
-- ---------------------------------------------------------------------------
alter table shots add column if not exists device_id uuid references devices(id) on delete set null;
alter table shots add column if not exists shot_at timestamptz;
create index if not exists idx_shots_exercise_no on shots (exercise_id, shot_no);
create index if not exists idx_shots_device on shots (device_id) where device_id is not null;
alter table shots drop constraint if exists shots_final_score_range;
alter table shots add constraint shots_final_score_range check (final_score >= 0 and final_score <= 10.9);

-- ---------------------------------------------------------------------------
-- Raw sensor traces per shot (vibration, 3D sway, pulse, trigger force ...).
-- One row = one channel of one shot; data is a compact array, NOT one row per sample.
-- ---------------------------------------------------------------------------
create table if not exists shot_samples (
  id         uuid primary key default gen_random_uuid(),
  shot_id    uuid not null references shots(id) on delete cascade,
  device_id  uuid references devices(id) on delete set null,
  channel    text not null,
  rate_hz    numeric not null check (rate_hz > 0),
  t0_ms      int not null default 0,
  data       real[] not null,
  extra      jsonb,
  created_at timestamptz not null default now()
);
create unique index if not exists uq_shot_samples_channel
  on shot_samples (shot_id, channel, coalesce(device_id, '00000000-0000-0000-0000-000000000000'::uuid));

-- Packages: query indexes and a value check
create index if not exists idx_packages_started on training_packages (started_at desc);
create index if not exists idx_exercises_package on exercises (package_id);

-- ---------------------------------------------------------------------------
-- Protection for the new tables: owner only, nothing for anon
-- ---------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['devices', 'series', 'shot_samples'] loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists "%1$s_owner_all" on %1$I', t);
    execute format(
      'create policy "%1$s_owner_all" on %1$I for all to authenticated using (is_project_owner()) with check (is_project_owner())',
      t);
    execute format('grant select, insert, update, delete on %I to authenticated', t);
    execute format('revoke all on %I from anon', t);
  end loop;
  foreach t in array array['devices', 'series'] loop
    execute format('drop trigger if exists touch_%1$s on %1$I', t);
    execute format('create trigger touch_%1$s before update on %1$I for each row execute function touch_updated_at()', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- Documentation for the next AI (table_docs)
-- ---------------------------------------------------------------------------
insert into table_docs (entry_key, kind, title, body) values
  ('devices', 'table', 'Hardware registry',
'One row per physical device: Argus (kind = argus), smart trigger (trigger), target system (target_system) or anything else (other).
calibration holds per-device calibration as a structure. Link data to a device through shots.device_id and
shot_samples.device_id. The device layer is deliberately separate from the training tables: it can be extended or
replaced without touching training_packages / exercises / shots.'),
  ('series', 'table', 'Series of an exercise (optional)',
'Optional per-series record: start/end time and a note. shots.series_no remains the key that groups shots;
a row here only adds information. Unique per (exercise_id, series_no).'),
  ('shot_samples', 'table', 'Raw sensor traces of a shot',
'One row = one channel of one shot (for example accel_x, gyro_z, pulse, trigger_force). data is a real[] array of
samples, rate_hz is the sampling rate, t0_ms is the offset of the first sample from the shot moment (negative =
before the shot). Do NOT store one row per sample: hundreds of samples per shot would bloat the database.
Derived numbers (peak force, sway amplitude) go to shots.extra.'),
  ('rule:schema-v2', 'rule', 'Schema v2 changes',
'exercises.template_id is a real foreign key to exercise_templates (extra.template_id is kept for compatibility).
exercises.id no longer has to equal the package id: shots are found by exercise_id of the exercises row; exercises of one
package are ordered by exercises.position (1, 2, ...). shots.final_score is limited to 0..10.9. shots.device_id and
shots.shot_at (absolute time) are optional. New tables: devices, series, shot_samples.')
on conflict (entry_key) do update
  set kind = excluded.kind, title = excluded.title, body = excluded.body, updated_at = now();

notify pgrst, 'reload schema';
