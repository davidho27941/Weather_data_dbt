# Data quality + observability: stronger tests + dashboard + dbt-test alert

## Summary

Two themes that ship together because they're naturally coupled — data
quality assertions need to flow into observability signals, and the
observability layer is what tells us when an assertion broke.

**Data quality (dbt)**:

- `relationships` test on every `fct_measurements_*.station_id` →
  `dim_stations.station_id` (severity=warn — see rationale below).
- `accepted_range` tests on every numeric measurement column in
  `fct_measurements_10min` (wind speed, pressure, precipitation, gust,
  UV, sunshine, wind direction). Bounds are wide enough to absorb real
  extremes (typhoon-day pressure 870 hPa, wind 78 m/s) but tight enough
  to catch sign errors and scale-of-10 bugs.
- New singular test `sentinel_translation_invariant.sql` — asserts that
  for every measurement field, a non-sentinel raw value must produce a
  non-null cleaned value. This is the strongest possible assertion
  about `cwa_string_to_float` correctness; severity=error.
- New singular test `anomaly_fct_measurements_daily_rowcount.sql` —
  z-score on daily row count vs. trailing 30-day baseline, fires when
  deviation exceeds 3σ. severity=warn (anomalies are not always bugs).

**Observability (Terraform)**:

- New log-based metric `dbt_test_failure_count` — counts dbt error-tier
  test failure log lines from the two dbt Cloud Run Jobs.
- New alert policy `dbt test — assertion failed` — fires on the metric
  > 0, routes to the existing email channel. Narrower signal than the
  generic Cloud Run Job failure alert (which bundles OOM / network /
  SQL / test errors together).
- New `google_monitoring_dashboard.pipeline_health` — single dashboard
  with four panels: Cloud Run Job executions by result, dbt test
  failures over time, BQ slot utilisation, crawler bucket bytes by
  storage class (so the new GCS lifecycle work is visible too).

**Docs**:

- New [`docs/slo.md`](../docs/slo.md) — explicit SLO targets, paging
  vs. investigate-later thresholds, where each signal lives.

## Why severity=warn on relationships

`dim_stations` is built fresh on every weekly run from the *latest*
CWA station snapshot. A station decommissioned mid-year disappears from
the source, and therefore from `dim_stations`, while its historical
measurements remain in the incremental `fct_measurements_*` tables.
That breaks referential integrity through no fault of the pipeline.

Two ways to handle it:

- **Hard fail (severity=error)**: forces a backfill of `dim_stations`
  to include historical decommissioned stations, every time. Adds
  ongoing maintenance toil for a relationship that's already
  enforceable by construction within a single build (dim runs before
  fct in the DAG).

- **Warn (chosen)**: surfaces the issue in dbt output and on the
  dashboard via the log-based metric, but does not fail the weekly
  build. A persistent warn signals an investigation: either backfill
  dim with the decommissioned station, or accept the drop with a
  documented exclusion.

The senior-DE-y reading: hard-fail on invariants that the system
should guarantee (uniqueness, sentinel translation, schema), warn on
inconsistencies that depend on upstream state we don't control
(station decommissions, anomaly-class events).

## Why severity=warn on the anomaly test

A z-score > 3σ on daily row count is *interesting*, not always
*broken*. Typhoon days legitimately spike observation density; prolonged
crawler outages legitimately depress it. Hard-failing the weekly build
on the first day a typhoon hits is wrong. Surfacing the signal so a
human can decide is right.

Trade-offs the test docstring calls out explicitly:

- Z-score assumes roughly-normal distribution. Daily row counts have
  weekday/weekend structure and seasonality; for tighter signal the
  next iteration would be MAD (median absolute deviation) or a 7-day
  weekday-aware baseline.
- 14-day baseline minimum gating before the test fires at all (avoids
  noisy false-positives on first runs).
- Catches sharp jumps, not slow drift (drift is absorbed into the
  moving baseline).

Chosen for explainability + zero dependencies. Upgrade to MAD if the
signal turns out to be too noisy.

## Why a second alert policy instead of folding into the existing one

The existing `Cloud Run Job — execution failed` policy fires on *any*
non-zero Job exit: OOM, network timeout, BQ auth error, dbt model SQL
error, dbt test failure — all the same alert text. That's fine as a
last-line-of-defence catch-all but useless for on-call triage.

The new `dbt test — assertion failed` policy is mutually compatible:

- A dbt test severity=error failure causes *both* alerts to fire.
- The new alert tells you "look at the dbt test summary, not the OOM
  killer."
- Future webhook channel work (Future work item) can route the two
  policies to different chat channels.

## Image-tag drift / TF lifecycle

No new `ignore_changes` blocks needed; the new resources are
fully-managed by TF. The dashboard JSON is built via `jsonencode()` so
it diffs cleanly in code review rather than as one opaque string.

## Changes

| File | Change |
|---|---|
| [`weather_data_dbt/models/marts/_models.yml`](../weather_data_dbt/models/marts/_models.yml) | + `relationships` tests on all 5 `fct_measurements_*.station_id`; + `accepted_range` on 9 numeric columns in `fct_measurements_10min` |
| [`weather_data_dbt/tests/sentinel_translation_invariant.sql`](../weather_data_dbt/tests/sentinel_translation_invariant.sql) | New singular test (severity=error) |
| [`weather_data_dbt/tests/anomaly_fct_measurements_daily_rowcount.sql`](../weather_data_dbt/tests/anomaly_fct_measurements_daily_rowcount.sql) | New singular test (severity=warn) |
| [`terraform/observability.tf`](../terraform/observability.tf) | New: `google_logging_metric.dbt_test_failure`, `google_monitoring_alert_policy.dbt_test_failure`, `google_monitoring_dashboard.pipeline_health` |
| [`docs/slo.md`](../docs/slo.md) | New: explicit SLO doc with response stance |
| [`README.md`](../README.md) + [`multilingual_readme/readme_jp.md`](../multilingual_readme/readme_jp.md) | Future work pruned; dashboards + SLO referenced |

## Test plan

dbt:

- [x] `dbt parse --target dev` — clean, no deprecation warnings.
- [x] `dbt list --resource-types test` shows the 16 new tests
      (5 relationships + 9 accepted_range + 2 singular).
- [ ] `dbt build --target stg` on the next weekly run passes all
      error-severity tests; warn-severity tests may legitimately fire
      and that's the signal we wanted.

Terraform:

- [x] `terraform validate` — passes.
- [x] `terraform plan` — `3 to add, 0 to change, 0 to destroy`:
      log-based metric, dashboard, alert policy. No drift on existing
      resources.
- [ ] `terraform apply` (manual; CI does not apply TF).
- [ ] Verify dashboard renders all 4 panels in the Console
      (`Monitoring → Dashboards → Weather pipeline health`).
- [ ] Smoke-test the alert policy: temporarily downgrade one
      `not_null` test to severity=error on a column that has nulls,
      trigger the weekly Job, confirm the email alert fires *and*
      shows "dbt test — assertion failed" (not just the generic Job
      failure). Revert the change after.

Docs:

- [x] [`docs/slo.md`](slo.md) written with explicit targets +
      response-stance table.
- [ ] Top-level README and JP README updated to remove completed
      Future work items.

## Out of scope (deferred to follow-ups)

- **Webhook alert channel** (Discord / Slack / Pub-Sub) — Future work.
  Email is still the single paging surface.
- **Freshness wrapper** that posts structured per-source detail.
- **`elementary-data`** layered on dbt artifacts — its anomaly module
  would supersede the singular z-score test eventually.
- **`sqlfluff` lint** in CI — separate code-quality concern.
- **Cost / performance dashboards** (per-model BQ slot, partition
  scan bytes) — separate cost-focused PR.

## References

- Branch: `feat/data-quality-observability` → `main`
- Gap analysis driving this scope: [`docs/portfolio_gap_analysis.md`](portfolio_gap_analysis.md)
  Tier 1 §1 (data quality) + §2 (observability)
