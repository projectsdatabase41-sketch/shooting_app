# Coach tasks in the Nexus app — reference for the AI

A task is a training plan the coach sends to an athlete. It does NOT go into ordinary
trainings: the shots, notes and reports are stored in the task itself.
All human-readable text (titles, instructions, questions, reports) is written in the
language of the coach description.

## Structure
Task → stages → steps.
- Stages go STRICTLY in order: the next one opens when the previous one is finished.
- Inside a stage there is a mode (`mode`):
  - `single` — one step, the athlete sees at once what to do;
  - `together` — several steps are done at the same time / in one session; shown
    as one page, separated in the record only for order;
  - `any_order` — ALL steps of the stage must be done, the athlete chooses the order;
  - `pick_one` — the athlete chooses ONE step from those offered.
- Example "two at once, then a mandatory one, then two in any order":
  stage 1 `together` [A, B] → stage 2 `single` [C] → stage 3 `any_order` [D, E].

## Step
- `title` — short, 2-6 words.
- `instructions` — the full text for the athlete: what and how to do. Carry over the
  coach words in full, leave nothing out.
- `exercise` — only for steps with shooting:
  `{"target_face_code": "rifle_10m", "shots": 20, "series_size": 10, "position": "prone"}`.
  Target codes: `rifle_10m` (10 m air rifle), `pistol_10m` (10 m air pistol),
  `rifle_50m` (50 m small-bore rifle), `pistol_25m` (25 m pistol). No shooting — do not set `exercise`.
- `time_limit_sec` — the step time limit, if the coach named one.
- `sighting` — sighters: `{"required": true, "max_shots": 10, "time_sec": 300}`
  (include only what is known). Sighters never count towards the score.
- `note_mode` — where to ask for the athlete note, based on the coach TEXT:
  `shot` — for every shot; `series` — after every series; `step` — a report at the end of
  the step (default); `none` — no notes needed.
- `keep_stats` — true if the coach asks to keep shared statistics with the previous step
  (do not reset the target). Default false — the target is clean on a new step.

## The whole task (JSON)
```
{"title": "…", "coach_text": "the coach text in full, as written",
 "due_at": "2026-10-03T18:00:00Z" | null, "repeat_rule": "daily" | "mon,wed,fri" | null,
 "stages": [{"mode": "single", "steps": [ {step}, … ]}, …]}
```

## Execution rules (know them when writing reports)
- A step with shooting is counted automatically from the result; an extra shot is allowed.
- Deviations from the plan (time is up, extra shots, no sighters) do not stop the
  athlete — they are only recorded as facts (`task_events`), with plan/actual figures.
- Time spent on notes is a legitimate reason for exceeding the limit; take it into account in conclusions.

## Common parsing mistakes
- Do NOT collapse repeated blocks into one step/stage. If the coach listed a sequence
  in words several times in a row, these are separate stages in order, even if the text
  is identical or almost identical. Count the elements by the separators ("+", "-", ",",
  "then", "after that") literally; do not try to find a repetition in them and shorten it.
- Do NOT add `exercise` to a step where the coach did not mention shooting (warm-up,
  push-ups, squats, stretching, running). A target is not implied by default — only when it
  is explicitly said "shooting", "shots", "series" and so on.
- Parsing example: the coach wrote (in Russian)
  "Отжимания + присед — стрельба без костюма — в костюме — отжимания —
  стрельба без костюма — в костюме" (push-ups + squats — shooting without the suit —
  in the suit — push-ups — shooting without the suit — in the suit). This is SIX
  consecutive stages (not three with a repeat and not one with "x2"):
  ```
  {"stages": [
    {"mode": "together", "steps": [{"title": "Отжимания"}, {"title": "Присед"}]},
    {"mode": "single", "steps": [{"title": "Стрельба без костюма", "exercise": {…}}]},
    {"mode": "single", "steps": [{"title": "Стрельба в костюме", "exercise": {…}}]},
    {"mode": "single", "steps": [{"title": "Отжимания"}]},
    {"mode": "single", "steps": [{"title": "Стрельба без костюма", "exercise": {…}}]},
    {"mode": "single", "steps": [{"title": "Стрельба в костюме", "exercise": {…}}]}
  ]}
  ```
  (the `exercise` parameters follow what the coach said about the target/series; if the
  coach did not say, omit them and ask a clarifying question if it matters for the structure).

## Clarifying questions
Ask ONLY if the structure cannot be built correctly without the answer; briefly, to the point.
Examples: "Are sighters needed when changing position?", "Is there a time limit for changing
position?", "A limit on the number of sighters when changing position?", "Notes for every shot
or for series?". Do not ask what has already been said.
