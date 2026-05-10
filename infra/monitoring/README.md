# Cloud Monitoring alerting

Email alerts when any of the three pipeline Cloud Run Jobs
(`bronze-daily-load`, `dbt-weekly-build`, `dbt-hourly-freshness`)
finishes a retry-exhausted execution with `result=failed`.

This single alert policy covers four practical failure modes:

| Mode | How it surfaces |
|---|---|
| Bronze daily MERGE fails (GCS read / SQL / IAM) | `bronze-daily-load` execution `failed` |
| dbt weekly build fails (compile / test / BQ) | `dbt-weekly-build` execution `failed` |
| dbt source freshness ERROR | `dbt-hourly-freshness` exits non-zero → execution `failed` |
| Image pulled / startup error | Same path — Cloud Run reports `failed` |

> Cloud Monitoring emits a generic "Job execution failed" email; the
> body links to the failed execution. Granular per-source freshness
> detail (e.g. "rain_fall_stations is X hours stale") is **not** in the
> email — that needs a freshness wrapper on a webhook channel and is
> tracked as a follow-up in [`docs/redesign_proposal.md`](../../docs/redesign_proposal.md) §13.4.2.

## Files

```
infra/monitoring/
├── README.md                                ← this file
├── deploy.sh                                ← one-shot apply: channel + policies
└── alert_policies/
    └── cloud_run_job_failure.yaml           ← the policy template (envsubst-rendered)
```

## One-time prerequisites

- Cloud Monitoring API enabled on the project (it usually is by default).
- Your active gcloud account (or the SA you run `deploy.sh` as) needs:
  - `roles/monitoring.notificationChannelEditor` on the project
  - `roles/monitoring.alertPolicyEditor` on the project
- An email address that you control. Cloud Monitoring sends a
  verification email the first time the channel is used; click the
  link in that email or alerts won't deliver.

## Apply

```bash
ALERT_EMAIL=davidho.prime@gmail.com ./deploy.sh
```

The script is idempotent:

- Looks up the email channel by `(type=email, labels.email_address, displayName)`. Reuses if present, creates if not.
- For each `alert_policies/*.yaml`:
  - `envsubst` substitutes `${NOTIFICATION_CHANNEL_ID}` (and any other env vars).
  - Looks up an existing policy by `displayName`. Creates if missing, updates in place if present.

Re-running on YAML edits will roll the policy forward without duplicating.

## Smoke test

Trigger a deliberate Job failure (e.g. pass an invalid dbt flag) and
watch for the email:

```bash
gcloud run jobs execute dbt-hourly-freshness \
  --region=asia-east1 \
  --args=source,freshness,--bogus-flag
```

The Job will fail (`exit 2` from dbt), execution registers as
`result=failed`, and within ~1–2 minutes you should receive an email
from Cloud Monitoring titled like *"Cloud Run Job — execution failed"*.

To restore the Job's normal args after the test:

```bash
cd infra/dbt
./deploy_jobs.sh    # idempotently re-applies the canonical args
```

## What is NOT in this policy

- **Granular freshness detail** in the email body. With email channel,
  the alert payload is constrained to Cloud Monitoring's templating —
  it can include the Job name and a link to the execution, but not a
  parsed dump of `target/sources.json`. Switch to a webhook channel
  (Discord / Slack / Pub/Sub → Cloud Function) and add a freshness
  wrapper if/when that level of detail becomes worth it.
- **GHA workflow failures**. CI/CD failures show up directly on the
  GitHub PR / Actions UI; they do not flow through Cloud Monitoring.
- **BQ data-quality / volume / freshness anomaly**. Out of scope —
  consider [`elementary-data`](https://github.com/elementary-data/elementary)
  on top of dbt artifacts for that.

## Migration notes

When/if the alert channel switches from email to a webhook
(Discord/Slack/Pub-Sub), the change is two lines:

1. Rename the channel display name (`pipeline-alerts (...)` → something
   neutral) and the channel `--type=` in `deploy.sh`.
2. Update `${NOTIFICATION_CHANNEL_ID}` reference in the YAML (no
   change needed if the env var indirection stays).

The alert policy itself (filter, threshold, auto-close) is reusable
across channel types.
