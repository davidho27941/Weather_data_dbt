# Service-level objectives — weather pipeline

Operational targets and the response stance when they are missed. SLOs
are intentionally informal at this scale; the goal is to make the
implicit "what does healthy look like" explicit, not to commit to a
contractual error budget.

Last reviewed: 2026-05-11.

## Pipeline overview

```
CWA APIs ──► weather-crawler ──► GCS ──► bronze (BQ weather_raw)
                                          │
                                          ▼
                                  weather_staging / intermediate / marts
                                  (dbt, weekly build Mon 02:30 Asia/Taipei)
```

Three orchestrated workloads, each with its own SLI:

| Workload | Cadence | Source-of-truth signal |
|---|---|---|
| `weather-crawler` (Cloud Run service) | Cloud Scheduler every 10 min | Successful POST + GCS object write |
| `bronze-daily-load` (Cloud Run Job) | Daily 02:00 Asia/Taipei | `weather_raw.observations` row count for yesterday's `dt=` partition |
| `dbt-weekly-build` (Cloud Run Job) | Weekly Mon 02:30 Asia/Taipei | dbt build summary (PASS on all error-severity tests) |
| `dbt-hourly-freshness` (Cloud Run Job) | Hourly | `dbt source freshness` PASS on `weather_raw.observations` |

## Targets

| SLI | Target | Measured by | If missed |
|---|---|---|---|
| **Bronze freshness** — most recent `ingest_at` in `weather_raw.observations` | < 36h (warn) / < 72h (error) | `dbt source freshness`, hourly | Email alert via dbt-hourly-freshness Job failure (when error threshold breached) |
| **Marts freshness** — most recent `measure_at` in `fct_measurements_daily` | < 14 days at any time | Spot-check / dashboard panel | Investigate within 1 business day; weekly build cadence makes < 7 day staleness expected |
| **Pipeline availability** — % of scheduled Cloud Run Job executions ending `result=succeeded` (rolling 30 days) | ≥ 95 % | `run.googleapis.com/job/completed_execution_count` | If < 95 %, investigate trend before next scheduled run |
| **Data quality** — error-severity dbt test pass rate per weekly build | 100 % | `dbt_test_failure_count` log-based metric | Critical alert (`dbt test — assertion failed`) → investigate same day |
| **Anomaly signal** — row-count z-score on `fct_measurements_daily` | warn-only | dbt test, severity=warn | Investigate within 3 business days; not a same-day page |
| **Image freshness** — every weekly main push rolls Cloud Run Job images forward | Within 60 min of merge | GHA `dbt_cd.yml` / `bq_cd.yml` run duration | Rollout failures trigger GHA red badge; investigate before next weekly run |

## Why these numbers, not stricter ones

- **Bronze freshness 36h / 72h warn / error**: bronze ingest runs once a
  day at 02:00 Asia/Taipei. Right after the run, freshness is ~2h;
  right before the next day's run, ~26h. A 30/90 minute threshold
  would ERROR for 24h every single day even when everything is fine.
  Numbers reflect *daily MERGE health*, not crawler health (the latter
  is covered by the Cloud Run Job execution alert).

- **Marts freshness < 14 days**: weekly build (Mon 02:30 Asia/Taipei)
  means the worst-case healthy staleness is ~7 days. The 14-day SLO
  doubles that to absorb one missed weekly build without paging.

- **95 % availability over 30 days**: at a weekly cadence, the marts
  Job runs 4–5 times per month. One failed run drops availability to
  ~80 % over 30 days — already noisy enough at this volume that a
  tighter SLO would over-page. The 95 % target is met by ≤ 1 failure
  per ~20 runs (i.e. ~5 months of clean operation).

- **dbt data-quality 100 %**: error-severity tests are *invariants*
  (sentinel translation correctness, schema uniqueness, referential
  integrity within the build). Any failure is a bug to fix, not a
  budget to spend.

## Response stance

```
┌────────────────────────────────────────────────────────────────────┐
│ Pager-worthy (email alert fires, investigate same day)             │
│  • Cloud Run Job execution failure (any of the three)              │
│  • dbt test — severity=error fails                                 │
│  • Bronze source freshness > 72h (error threshold)                 │
├────────────────────────────────────────────────────────────────────┤
│ Investigate within 1–3 business days (dashboard panel)             │
│  • Bronze source freshness 36h–72h (warn)                          │
│  • Row-count anomaly z-score > 3                                   │
│  • relationships test fails (warn) — station decommissioned        │
│  • GCS lifecycle transitions look stale on the dashboard           │
├────────────────────────────────────────────────────────────────────┤
│ Watch (no immediate action)                                        │
│  • BQ slot consumption trend                                       │
│  • Crawler bucket byte growth                                      │
└────────────────────────────────────────────────────────────────────┘
```

The email channel is the single source of paging today. The Future
work item *Webhook alert channel (Discord / Slack / Pub-Sub) +
freshness wrapper* would let warn-tier signals stream to a chat
channel without paging — recommended as the next observability change.

## Where each signal lives

| Signal | Path |
|---|---|
| Email alerts | `terraform/monitoring.tf` + `terraform/observability.tf` |
| Cloud Monitoring dashboard | `google_monitoring_dashboard.pipeline_health` in `terraform/observability.tf` |
| Log-based metric `dbt_test_failure_count` | `terraform/observability.tf` |
| dbt source freshness configuration | `weather_data_dbt/models/staging/_sources.yml` |
| dbt data tests | `weather_data_dbt/models/*/_models.yml` + `weather_data_dbt/tests/` |
| Job duration / execution count metrics | Built-in `run.googleapis.com/job/*` (no setup) |

## Open gaps

Tracked as Future work in [`README.md`](../README.md#future-work):

- Webhook channel for granular per-source freshness payloads (email can
  only carry coarse strings).
- Cloud Monitoring dashboards beyond the single pipeline-health view —
  e.g. cost drill-down, per-model build duration.
- Anomaly detection beyond the single daily-row-count test — e.g.
  per-column null-rate drift, weekday-aware baseline.
