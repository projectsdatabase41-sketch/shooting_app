-- English source of the AI-facing documentation (table_docs), the table_protection view
-- and the self-check query. tools/build_personal_sql.py puts this text into
-- lib/db/nexus_personal_db.sql in place of the Russian originals from puls_install.sql.

comment on table table_docs is
  'How to work with this database: what each table is for and the general rules. Read before writing any data.';

insert into table_docs (entry_key, kind, title, body) values
  ('training_packages', 'table', 'A whole training session', 'One row = one training session (TrainingSession in the app).
It may contain several exercises; the app currently writes exactly one.
started_at / ended_at are the shooting times. time_is_approximate = true when the time
was restored from a device report rather than recorded live.
extra describes what kind of shooting it was: {"event":{"kind":"championship","stage":"final","title":"..."}}.
kind: training | control | regional | championship | final.
NOTE: the app does not read title and note yet - use a session-level comment for visible text.'),
  ('exercises', 'table', 'Snapshot of an exercise performed inside a package', 'NOT the exercise catalog - the catalog is exercise_templates.
package_id is the training it belongs to. The link to the template is stored in
extra.template_id; without it the app cannot match the training to the exercise during
sync and creates a local duplicate.
discipline = target_faces.code.'),
  ('exercise_templates', 'table', 'Exercise catalog (templates)', 'Look it up by name + target_face_id before inserting and REUSE it across
trainings. Never create a new row per file - otherwise the history falls apart into a dozen
identical exercises and the "by exercise" slice stops meaning anything.'),
  ('shots', 'table', 'A shot', 'x_mm / y_mm are millimetres from the target centre. The X axis points right, the Y axis points UP.
A flipped Y sign mirrors the group while the score total still adds up perfectly, so the error is invisible.
final_score is the device/protocol result AS IS and is never recalculated from coordinates:
on a tenth-of-a-point boundary a recalculation gives 10.5 where 10.4 is written.
counts = false marks a sighting shot: it is visible on the target but is excluded from the total and
statistics. The flag lives on the shot; it is not derived from the exercise when reading.
coordinate_source: tap | score_angle | file_import | pdf | photo | auto | manual_corrected.
source: manual | file_import | pdf | photo | auto | manual_corrected. The values are limited by CHECK
constraints - your own word (e.g. scatt) will be rejected: the device name goes into extra, not into the source.
shot_time_ms is an OFFSET from the start of the exercise in milliseconds, type integer.
Epoch time does not fit (int4 overflow).
extra holds device metrics as a structure: {"scatt":{"aim_time_s":18.4,...}}.'),
  ('comments', 'table', 'Human notes', 'Text written by the athlete or the coach. level: shot | series | session | coach.
Device metrics must NOT be written here, even with a label: an assistant cannot compute anything from the
line "aiming time 18.4 s", and personal notes drown in the machine stream. Numbers go to shots.extra.'),
  ('training_notes', 'table', 'Standalone diary', 'Entries not tied to a training. The assistant invents a topic when saving, but the
text stays ordinary editable text.
Deletion is two-step: is_trashed first, then real deletion.
Do not confuse it with the notes table - that is a separate knowledge base for the AI (see protect:notes).'),
  ('target_faces', 'table', 'ISSF target reference', 'The app takes geometry from its own constants (lib/models/target_face.dart); this table is an
anchor for foreign keys and a readable decoding of the code.
Working codes (ring_config is filled): rifle_10m (No. 8), pistol_10m (No. 9), rifle_50m (No. 7),
pistol_25m (No. 4).
Four more rows from the first schema version may exist - air_rifle_10m, air_pistol_10m,
sb_rifle_50m, sb_pistol_25m - with an empty ring_config; the app does not know these codes.
Do NOT reference them (factory templates once referenced them and showed a target without rings -
fixed on 2026-09-08 by sql/fix-legacy-target-faces.sql). Nothing references them now; still, do not
delete them without asking.
Rows are looked up by code and are not duplicated.'),
  ('project_settings', 'table', 'Database owner and settings', 'Exactly one row per owner, owner_user_id = auth.uid().
WITHOUT IT row-level security closes everything: is_project_owner() returns false, reading included.
It is created by the APP automatically on the owner''s first sign-in (the first one to sign in
becomes the owner; a second person cannot).
storage_balance: local_first | balanced | cloud_first.
status: active | paused | archived.'),
  ('file_assets', 'table', 'Files: target photos, reports', 'Linked to a package and (optionally) to an exercise. upload_status and
processing_status lead the file from upload to parsing.'),
  ('photo_import_jobs', 'table', 'Target photo parsing', 'One job = one picture. detected_shots_count is how many holes were found,
confirmed_at is when a person confirmed the parsing result.
The target type COMES INTO the parsing from the exercise and is not detected from the photo:
the training is created before the picture is taken. Rings are searched for the centre, scale,
rotation and perspective; ring numbers 1-8 remove the scale ambiguity. After calibration the hole
diameter is compared with the exercise calibre - a mismatch means wrong calibration.'),
  ('remote_athlete_sources', 'table', 'Athlete databases on the coach side', 'project_url + a reference to the access token. The coach connects to the athlete''s
database for reading and commenting.'),
  ('archived_packages', 'table', 'Coach-side copy of someone else''s training', 'package_json is a full snapshot at the time of export. It keeps the coach''s diary from
falling apart if the athlete revokes access.'),
  ('share_grants', 'table', 'Coach access tokens', 'Only token_hash is stored - the original token is shown once and cannot be restored.
revoked_at MUST be checked ON EVERY call: a revoked token stops returning data immediately.
If expires_at is set, check it too.'),
  ('share_events', 'table', 'Token access log', 'Who read the diary and when. For investigating "why the coach sees the wrong thing".'),
  ('rule:coordinates', 'rule', 'Coordinates', 'X axis to the right, Y axis UP, origin at the target centre, units are millimetres.
A shot is stored not as a number but as a point: score, group centre (mean point of impact),
dispersion and drift direction are computed from the coordinates.'),
  ('rule:score', 'rule', 'Scoring', 'Computed from the edge of the hole nearest to the centre: R_calc = R - calibre/2,
then the ring number by the official boundaries and the tenth as
floor((boundary - R_calc)/step), 0..9. A boundary belongs to the higher value. Scale 10.9...0.
The "whole" total drops the tenths of EACH shot separately:
10.9 + 10.9 + 9.9 = 31.7 in tenths and 29 in whole points.'),
  ('rule:sources', 'rule', 'Where to get coordinates', 'A ladder in descending order of accuracy:
A. Real coordinates (vector holes in a SCATT PDF, a device CSV) - take as is.
B. Result + picture: the radius FROM THE RESULT (accuracy ~0.08 mm), the angle FROM THE PICTURE.
   Eight sectors give an error up to 5.3 mm - they are not good as the final angle.
C. Results only - write the result, no coordinates. This is more honest than an invented position.'),
  ('rule:extra', 'rule', 'What to write into extra', 'Everything that has no column: device metrics, event markup. As a structure,
under a key named after the source. Adding new columns for every device is a dead end - there
will be more devices over time.'),
  ('rule:idempotency', 'rule', 'Repeated writes', 'Identifiers are deterministic - md5(source_key || '':'' || number)::uuid, inserted with
on conflict do nothing. A repeated import run must not create duplicates. The flip side: you cannot
re-upload corrected data over the old - delete first.'),
  ('rule:schema-changes', 'rule', 'Schema changes', 'The schema changes ONLY through the install files (this file or the originals under sql/).
create table if not exists on an existing table does NOT add columns - for those use
alter table ... add column if not exists.
The last line of any change: notify pgrst, ''reload schema'' - otherwise PostgREST keeps returning
an error about a non-existent column.')
on conflict (entry_key) do update
  set title = excluded.title,
      body = excluded.body,
      updated_at = now();

insert into table_docs (entry_key, kind, title, body) values
  ('rule:import-access', 'rule', 'Access when writing - read first',
'table_docs can be read with the public (anon) key. The public key does NOT allow WRITING to the
training tables (training_packages, exercises, exercise_templates, shots, comments, file_assets):
the policies require is_project_owner(), i.e. a sign-in as the database owner (email + password ->
JWT, header Authorization: Bearer). Do NOT use the service_role key (it bypasses protection) for
import and do not ask for it in chat: it can wipe the whole database. No owner JWT -> write nothing,
tell the person that a sign-in is needed instead of trying to get around it.'),

  ('rule:import-procedure', 'rule', 'How to enter a training from a PDF/photo/table - step by step',
'STEP 0. Read: select entry_key, body from table_docs (all rule:* and the tables) and the target
        reference target_faces (code, id).
STEP 1. ASK the person, do not guess: which exercise and TARGET (code from target_faces: rifle_10m,
        pistol_10m, rifle_50m, pistol_25m), the date and start time, how many scored shots and whether
        there are sighting shots. The target is an input parameter - do not detect it from the
        picture (see rule:sources).
STEP 2. Parse the source into a list of shots: number, series, the result AS WRITTEN (with tenths:
        10.6), coordinates if the source has them (level A).
STEP 3. Check BEFORE writing (see rule:import-checks). If it does not add up - do not write, show
        the person the mismatch.
STEP 4. Write in this order (every row is an insert with a deterministic id,
        Prefer: resolution=ignore-duplicates, see rule:idempotency):
  4.1 exercise_templates - first SEARCH by exercise_name + target_face_id, create only if missing
      (do not create duplicates). Fields: code = ''custom_'' || id, name, weapon_type (''rifle'' for
      rifle_*, ''pistol'' for pistol_*), ammo_type (''air'' for 4.5 mm, ''smallbore'' for 5.6 mm),
      distance_m, shots_count, shots_per_series, target_face_id, is_custom = true.
  4.2 training_packages - id = X (a new deterministic uuid), started_at (with time zone), ended_at if
      known, package_status = ''completed'' (only completed counts as a finished training in the app;
      draft/active show up as "not started"), time_is_approximate = true if the time was restored.
      extra: {"event":{"kind":"training"},"import":{"by":"<AI name>","source":"pdf|photo|csv"}}.
  4.3 exercises - EXACTLY ONE row per package, and its id MUST EQUAL the package id (id = X,
      package_id = X). Otherwise the app cannot find the shots (it looks them up by
      exercise_id = package id) and the training arrives empty. Fields: exercise_name,
      discipline = target code, distance_meters, target_face_id, decimal_scoring = true,
      expected_shots.
  4.4 shots - exercise_id = X. shot_no runs 1..N through the whole exercise, series_no,
      final_score = the source result AS IS (do not recalculate from coordinates),
      reported_score = the same, x_mm / y_mm (Y positive upward), counts = false for sighting,
      confirmed = true, coordinate_source and source from the allowed ones:
      pdf | photo | file_import (see shots), shot_time_ms - an offset from the start in ms (integer)
      or null, extra - device metrics as a structure.
  4.5 comments - human text only (level: shot|series|session|coach). Device metrics go to
      shots.extra, not here.
STEP 5. Read back what was written (GET by id) and show the person a summary: target, date, shot
        count, total per series and overall. Ask them to open the app and compare; fix any
        mismatch instead of ignoring it.
If something is missing (no target, no date, unreadable) - stop and ask. A missing field is better
left empty than invented.'),

  ('rule:import-checks', 'rule', 'Checks before writing (mandatory, they catch the errors of any model)',
'1. The number of shots matches expected_shots (+ sighting separately, counts = false).
2. The sum of results matches the total printed in the source - for every series and overall.
   Tenths are summed as tenths; "whole" points drop the tenths of EACH shot separately (rule:score).
3. Every result is in the allowed range: 0..10.9 for decimal scoring.
4. Shot numbering is continuous, with no gaps or repeats; series in order.
5. Photo: the hole diameter by the exercise calibre (4.5 / 5.6 mm) matches the claimed one -
   otherwise the scale is wrong, do not trust the coordinates (DATA-INGEST section 3).
6. Y axis sign: a shot above the centre on paper -> y_mm > 0. A flipped sign mirrors the group
   while the sum still matches - the only way to notice is to compare 2-3 shots with the picture.
7. The source has no coordinates: do NOT write null and do NOT write 0/0 (the app reads empty as 0 -
   all shots land in the centre and the training looks empty). Take the radius from the result
   (rule:radius-formula), the direction from the source (arrow, clock, drawing) or, if it is nowhere,
   spread the angles by the golden angle (i*137.5 degrees), write {"coordinates":"direction unknown
   (conditional)"} into shots.extra and tell the person that the points are conditional.
If any check fails -> do NOT write silently and do NOT fit the numbers, show the mismatch to the person.'),

  ('rule:radius-formula', 'rule', 'Coordinates from a result and a direction (formula)',
'If you write x_mm / y_mm yourself. Direction: 0 degrees = up, clockwise; 3 o''clock = 90,
6 o''clock = 180; clock: hour*30 + minutes*0.5; arrows: up 0, up-right 45, right 90, down-right 135,
down 180, down-left 225, left 270, up-left 315.
Result ring.decimal (10.6 -> ring = 10, decimal = 6):
  d = max(0, R10 + W*(10 - ring) - (decimal + 0.5) * W/10 + K)
  x_mm = d * sin(angle);  y_mm = d * cos(angle)      -- the Y axis points UP
Per target (R10, W, K, mm): rifle_10m 0.25/2.5/2.25; pistol_10m 5.75/8/2.25;
rifle_50m 5.2/8/2.8; pistol_25m 25/25/2.8. Below one (a miss) - beyond the outer ring.
Check: rifle_50m 10.6 -> 2.8; rifle_10m 10.6 -> 0.875; pistol_25m 9.0 -> 51.55.
It is simpler not to calculate: the app''s import file accepts a result + a direction and calculates
by itself (see the public instruction table "Puls: how to determine shot coordinates").
The obsolete example "5.2 - 1.1 = 4.1" (an old model) must NOT be used.'),

  ('rule:import-model', 'rule', 'Which model to use for import (warning)',
'Import from a PDF/photo is a task where a cheap or small model errs SILENTLY: it mixes up the Y axis
sign, shifts the ring number, loses tenths, "invents" rows that are not in the source. The error
is invisible: the sums may still match.
Recommendation (cannot be verified - the database does not see the model, this is an agreement):
 - for parsing PHOTOS and scans use a strong model with good vision and arithmetic; cheap/free ones
   only for clean text/CSV, and still with the checks from rule:import-checks;
 - if the model is unsure about the source - stop and ask the person instead of writing "the most
   likely";
 - show the result of every import to the person for comparison (step 5).
The main protection is not the choice of a model but the checks and the human comparison: they catch
the error of any model.')

on conflict (entry_key) do update
  set kind = excluded.kind, title = excluded.title, body = excluded.body, updated_at = now();

insert into table_docs (entry_key, kind, title, body) values
  ('rule:protection', 'rule', 'Table protection - read before changing rights or deleting anything',
'1. Do NOT delete tables, columns or rows and do NOT change RLS policies/grants (grant/revoke)
   "because it looks unneeded". First run select * from table_protection and read the
   protect:<table> entry in table_docs.
2. All app tables: access only for the database owner through is_project_owner(). The anon role
   (public key without sign-in) has NO access to the tables - do not grant it. Exceptions:
   table_docs (readable by everyone - it contains rules, not data) and the functions through which a
   coach reads the diary by token (they check the token inside).
3. The schema changes only through the install files (see rule:schema-changes).
4. If you changed the protection - update protect:<table> and this entry.'),

  ('protect:notes', 'table', 'notes - knowledge base for the AI',
'Notes/knowledge: topic, summary, content (often empty - the text is in summary), tags (text[]),
source, status (active|archived|superseded), version/supersedes, confidence, metadata,
search_vector (full text, computed automatically), embedding + embedding_model +
embedding_created_at (semantic vector).
EMBEDDING FRESHNESS RULE: an embedding is current only if embedding_created_at EQUALS updated_at.
Editing the content moves updated_at (trigger), the embedding becomes stale and is recomputed by a
worker. Do not edit embeddings by hand.
Access: owner only (policy notes_owner_all). The built-in assistant of the app reads this table if you
connect it in Settings -> Data and sync -> Account -> Tables for AI. An external AI may also write notes -
signed in as the owner. Do NOT delete the table and do not rename the columns topic/summary/content:
the app reads them.'),

  ('protect:ai_conversation_summaries', 'table', 'ai_conversation_summaries - assistant memory',
'One row = one question-answer exchange (a short extract, not the full text). Written and read by the
app (AiMemoryService), at most 1000 rows are kept - the extra ones are erased automatically.
Access: owner only. Deleting the table = the assistant forgets past conversations.'),

  ('protect:keepalive_log', 'table', 'keepalive_log - database pulse',
'One row (id = 1): the time and the counter of the last puls_keepalive() call. GitHub calls it every
couple of days so that a free Supabase project does not go to sleep. Nobody has direct access
(there are no policies) - only through the function. Do NOT delete the table and the function:
the project will fall asleep and the first request after a pause will take minutes.'),

  ('protect:table_docs', 'table', 'table_docs - this very instruction',
'Written by the owner only, readable by anyone. It is the project memory of what the tables mean and
what must not be touched. Do NOT delete or "simplify" it: the next AI learns the rules from it.')
on conflict (entry_key) do update
  set kind = excluded.kind, title = excluded.title, body = excluded.body, updated_at = now();

create or replace view table_protection with (security_invoker = on) as
select c.relname                                   as table_name,
       c.relrowsecurity                            as rls_enabled,
       coalesce((
         select string_agg(p.policyname || ' [' || p.cmd || ' -> ' || array_to_string(p.roles, ',') || ']',
                           '; ' order by p.policyname)
         from pg_policies p
         where p.schemaname = 'public' and p.tablename = c.relname
       ), '- no policies -')                       as policies,
       exists (
         select 1 from table_docs d
         where d.entry_key = c.relname or d.entry_key = 'protect:' || c.relname
       )                                           as documented
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind = 'r'
order by c.relname;

with required_tables(name) as (values
  ('project_settings'), ('target_faces'), ('exercise_templates'), ('training_packages'),
  ('exercises'), ('file_assets'), ('photo_import_jobs'), ('shots'),
  ('remote_athlete_sources'), ('archived_packages'), ('share_grants'), ('share_events'),
  ('comments'), ('training_notes'), ('ai_conversation_summaries'),
  ('notes'), ('keepalive_log'), ('table_docs')
),
required_functions(name) as (values
  ('touch_updated_at'), ('touch_updated_at_on_content_change'),
  ('project_has_owner'), ('is_project_owner'), ('hash_share_token'), ('validate_share_token'),
  ('revoke_share_grant'), ('set_project_status'), ('get_shared_packages'), ('get_shared_exercises'),
  ('get_shared_shots'), ('get_shared_comments'), ('add_shared_comment'), ('list_public_tables'),
  ('notes_needing_embedding'), ('set_note_embedding'), ('search_notes'), ('puls_keepalive')
)
select * from (
  select 1 as n, 'All app tables are present' as check_name,
         not exists (select 1 from required_tables r
                     where not exists (select 1 from pg_tables t where t.schemaname = 'public' and t.tablename = r.name)) as ok,
         coalesce((select string_agg(r.name, ', ') from required_tables r
                   where not exists (select 1 from pg_tables t where t.schemaname = 'public' and t.tablename = r.name)),
                  'all ' || (select count(*) from required_tables) || ' present') as details
  union all
  select 2, 'All functions are present',
         not exists (select 1 from required_functions f
                     where not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                                       where n.nspname = 'public' and p.proname = f.name)),
         coalesce((select string_agg(f.name, ', ') from required_functions f
                   where not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                                     where n.nspname = 'public' and p.proname = f.name)),
                  'all ' || (select count(*) from required_functions) || ' present')
  union all
  select 3, 'Row-level security (RLS) is enabled on ALL tables',
         not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
                     where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity),
         coalesce((select string_agg(c.relname, ', ') from pg_class c join pg_namespace n on n.oid = c.relnamespace
                   where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity), 'enabled everywhere')
  union all
  select 4, 'Extensions pgcrypto and vector are installed',
         (select count(*) from pg_extension where extname in ('pgcrypto', 'vector')) = 2,
         coalesce((select string_agg(extname, ', ') from pg_extension where extname in ('pgcrypto', 'vector')), 'none')
  union all
  select 5, 'Target reference: 4 rows',
         (select count(*) from target_faces) = 4,
         (select count(*) from target_faces)::text || ' rows'
  union all
  select 6, 'Anonymous (public key without sign-in) has NO access to the app tables',
         not exists (select 1 from information_schema.role_table_grants
                     where table_schema = 'public' and grantee = 'anon' and table_name <> 'table_docs'),
         coalesce((select string_agg(distinct table_name, ', ') from information_schema.role_table_grants
                   where table_schema = 'public' and grantee = 'anon' and table_name <> 'table_docs'),
                  'no access (except reading table_docs - by design)')
  union all
  select 7, 'Owner exists (appears after the FIRST sign-in in the app)',
         (select count(*) from project_settings) = 1,
         case (select count(*) from project_settings)
           when 0 then 'not yet - sign in to the app with your email'
           when 1 then 'one owner - as it should be'
           else 'WARNING: more than one owner'
         end
  union all
  select 8, 'Database pulse is ready (keepalive_log exists; the call counter grows while GitHub is working)',
         (select last_ping from keepalive_log where id = 1) is not null,
         'calls: ' || (select pings from keepalive_log where id = 1)::text ||
         ', last: ' || (select last_ping from keepalive_log where id = 1)::text
  union all
  select 9, 'AI instructions loaded (table_docs)',
         (select count(*) from table_docs) >= 20,
         (select count(*) from table_docs)::text || ' entries'
  union all
  select 10, 'Sample notes are present (notes)',
         (select count(*) from notes) >= 1,
         (select count(*) from notes)::text || ' entries'
) checks
order by n;
