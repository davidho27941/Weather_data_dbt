# Cloud Monitoring alerting for pipeline Cloud Run Jobs

## Summary

Wires a Cloud Monitoring email alert for the three pipeline Cloud Run
Jobs landed in PR #3 (`bronze-daily-load`, `dbt-weekly-build`,
`dbt-hourly-freshness`). A single alert policy fires on
`run.googleapis.com/job/completed_execution_count{result=failed}`
filtered to those three jobs; the alert is delivered to an email
notification channel managed alongside the policy.

## Why this is its own PR

The three Cloud Run Jobs from PR #3 work, but a failed run was silent —
no notification. This is the smallest closure of that gap: one alert
policy, one notification channel, one idempotent deploy script. Bigger
follow-ups (webhook channels, granular freshness payloads, Terraform,
WIF) are intentionally out of scope.

## Coverage

A single failed-execution metric covers four practical failure modes:

| Mode | How it surfaces |
|---|---|
| Bronze daily MERGE fails (GCS / SQL / IAM) | `bronze-daily-load` execution `failed` |
| dbt weekly build fails (compile / test / BQ) | `dbt-weekly-build` execution `failed` |
| dbt source freshness ERROR | `dbt-hourly-freshness` exits non-zero → execution `failed` |
| Image pull / container startup error | Same path — Cloud Run reports `failed` |

The alert is **per-execution after retry exhaustion**, not per-task —
meaning it fires once when a Job ultimately fails, not once per retry.

## Changes

### `infra/monitoring/`

| File | Purpose |
|---|---|
| [`infra/monitoring/README.md`](infra/monitoring/README.md) | Operator runbook + smoke-test |
| [`infra/monitoring/deploy.sh`](infra/monitoring/deploy.sh) | Idempotent: ensures email channel, applies all `alert_policies/*.yaml` |
| [`infra/monitoring/alert_policies/cloud_run_job_failure.yaml`](infra/monitoring/alert_policies/cloud_run_job_failure.yaml) | Alert policy template; `envsubst`-rendered with `${NOTIFICATION_CHANNEL_ID}` at deploy time |

The deploy script is fully idempotent:

- Looks up the email channel by `(type=email, labels.email_address, displayName)`. Reuses if present, creates if not.
- For each policy YAML: looks up an existing policy by `displayName`. Creates if missing, updates in place if present.

Re-running on YAML edits rolls the policy forward without duplicating.

## Test plan

- [ ] Active gcloud account has `roles/monitoring.notificationChannelEditor`
      and `roles/monitoring.alertPolicyEditor` on `side-project-staging`.
- [ ] `ALERT_EMAIL=davidho.prime@gmail.com ./infra/monitoring/deploy.sh`
      runs cleanly, prints the resulting policy ID.
- [ ] Cloud Monitoring sends a verification email — click the link to
      confirm the channel.
- [ ] Smoke test: run `dbt-hourly-freshness` with a bogus arg so it
      exits non-zero:
      ```bash
      gcloud run jobs execute dbt-hourly-freshness \
        --region=asia-east1 \
        --args=source,freshness,--bogus-flag
      ```
- [ ] Email arrives within 1–2 min titled like *"Cloud Run Job —
      execution failed"*; body contains the failed execution's name and
      a deep link to Console.
- [ ] Restore the Job's canonical args:
      ```bash
      ./infra/dbt/deploy_jobs.sh
      ```

## What is NOT in this PR

Deferred to PR #5 (or later):

- **Webhook (Discord / Slack / Pub-Sub) notification channel.** Email
  is sufficient signal for "something broke" but not for granular
  freshness payloads ("`rain_fall_stations` is X hours stale"). Needed
  before §13.4.2's freshness wrapper makes sense.
- **Freshness wrapper** (§13.4.2). Pairs with webhook channel — the
  wrapper parses `target/sources.json` and posts structured detail
  that webhooks render usefully but email can't.
- **Cloud Monitoring dashboards** for pipeline health (Job duration
  trends, BQ slot consumption, GCS object age).
- **Workload Identity Federation** for GitHub Actions. Tracked in
  [`.github/workflows/README.md`](.github/workflows/README.md).
- **Terraform** of SA / IAM / Cloud Run Jobs / Schedulers / alerts.
- **BQ data-quality monitoring** (e.g.
  [`elementary-data`](https://github.com/elementary-data/elementary)
  layered on dbt artifacts).

## References

- Design doc: [`docs/redesign_proposal.md`](docs/redesign_proposal.md)
  §13.9 (P0 alerting), §13.4.2 (freshness wrapper sketch)
- Branch: `feat/alerting` → `main`
