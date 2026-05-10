# Terraform: IaC for the pipeline GCP infrastructure

## Summary

Adds a single Terraform root (`terraform/`) that codifies everything the
shell-script onboarding from PR #3 + PR #4 created in GCP:

- 5 service accounts (`dbt-runner`, `bronze-loader`, `scheduler-invoker`, `gha-ci`, `gha-cd`)
- Artifact Registry repo `dbt`
- Project / repo / bucket / SA-act-as IAM bindings
- Three managed BQ datasets (`weather_staging`, `weather_intermediate`, `weather_marts`) + dataset-level IAM
- Three Cloud Run Jobs (`bronze-daily-load`, `dbt-weekly-build`, `dbt-hourly-freshness`)
- Three Cloud Scheduler triggers + invoker IAM
- Email notification channel + Cloud Run Job failure alert policy

State lives in `gs://weather-pipeline-tfstate` (versioning on,
uniform-bucket-level-access). Bootstrap is one shell script;
`import.sh` pulls the existing GCP inventory into Terraform state so the
first `terraform plan` is near-zero diff (no resources are recreated).

## Why this is its own PR

PR #3 + PR #4 produced a working pipeline via shell scripts. Those
scripts are great for "stand it up the first time" but not for
- diffing intent against reality (drift detection)
- branching off into a `prod` env (currently all hardcoded staging values)
- recovering from accidental delete (no source of truth other than git
  history of shell scripts + live GCP state)

Terraform fills those gaps. We import rather than recreate, so this PR
is a no-op at apply time — the value is the new ground truth.

## Out of scope

- **GHA secrets / variables.** Adding the GitHub provider would put a
  PAT in tfstate; not worth the trade-off at this scope. Continue
  managing the two `GCP_SA_KEY_*` secrets manually per
  [`.github/workflows/README.md`](.github/workflows/README.md).
- **SA JSON keys for `gha-ci` / `gha-cd`.** Keys never live in tfstate.
  Continue creating them manually.
- **`weather_raw` dataset itself.** Only IAM is TF-managed; the dataset
  is owned by the bronze layer's bulk-load history.
- **The crawler GCS bucket itself.** Only the `bronze-loader` viewer
  binding is TF-managed.
- **`weather_dev_*` and `weather_ci_*` datasets.** Created on demand by
  dbt; ephemeral / per-developer.

## Image-tag drift handling

The three Cloud Run Jobs use `lifecycle.ignore_changes` on the
container image attribute. GHA's `dbt_cd.yml` / `bq_cd.yml` workflows
roll image tags on every main push touching `weather_data_dbt/**` or
`infra/{dbt,bq}/**`. If Terraform asserted a fixed tag, every CD run
would create perpetual drift; the lifecycle block opts out cleanly so
both systems coexist.

Cron schedules are exposed as `var.schedules` — change the cron, re-plan,
re-apply, no other surface to touch.

## Changes

### `terraform/`

| File | Purpose |
|---|---|
| [`README.md`](terraform/README.md) | Bootstrap + import + apply runbook + role requirements |
| [`versions.tf`](terraform/versions.tf) | `required_version >= 1.6.0`; google provider `~> 6.0` |
| [`backend.tf`](terraform/backend.tf) | GCS backend on `weather-pipeline-tfstate` |
| [`providers.tf`](terraform/providers.tf) | google provider with project / region defaults |
| [`variables.tf`](terraform/variables.tf) | project, region, ar_repo, gcs_bucket, alert_email, schedules |
| [`terraform.tfvars.example`](terraform/terraform.tfvars.example) | Copy-and-edit template |
| [`locals.tf`](terraform/locals.tf) | Computed values shared across files |
| [`service_accounts.tf`](terraform/service_accounts.tf) | The 5 managed SAs with descriptions |
| [`artifact_registry.tf`](terraform/artifact_registry.tf) | The `dbt` AR repo |
| [`iam.tf`](terraform/iam.tf) | Project / repo / bucket / act-as bindings |
| [`bigquery.tf`](terraform/bigquery.tf) | 3 managed datasets + dataset-level IAM (incl. weather_raw read/write grants) |
| [`cloud_run_jobs.tf`](terraform/cloud_run_jobs.tf) | 3 Cloud Run Jobs with image-tag drift suppression |
| [`cloud_scheduler.tf`](terraform/cloud_scheduler.tf) | 3 Schedulers + invoker IAM |
| [`monitoring.tf`](terraform/monitoring.tf) | Email channel + cloud-run-job-failure alert policy |
| [`outputs.tf`](terraform/outputs.tf) | SA emails, Job names, scheduler names, channel + policy IDs |
| [`bootstrap/create_state_bucket.sh`](terraform/bootstrap/create_state_bucket.sh) | One-time idempotent state bucket setup |
| [`import.sh`](terraform/import.sh) | `terraform import` for the existing PR #3 + #4 inventory |
| [`.gitignore`](terraform/.gitignore) | `.terraform/`, `*.tfstate*`, `terraform.tfvars`, `tfplan` |

## Test plan

- [ ] `cd terraform && ./bootstrap/create_state_bucket.sh` — succeeds
      whether the bucket exists or not.
- [ ] `cp terraform.tfvars.example terraform.tfvars`, edit `alert_email`.
- [ ] `terraform init` — connects to GCS backend cleanly.
- [ ] `ALERT_EMAIL=davidho.prime@gmail.com ./import.sh` — re-runnable;
      already-imported lines log "skipped" rather than error.
- [ ] `terraform plan` — output is near zero (IAM ordering noise is
      acceptable; resource recreation is not).
- [ ] If plan shows unexpected changes, iterate on the `.tf` until plan
      is clean **before** any `terraform apply`.
- [ ] After clean plan: `terraform apply` (should be zero or near-zero
      changes) — confirm Job arg / scheduler cron / monitoring policy
      attributes are unchanged in Console afterward.
- [ ] Sanity test the live system still works: trigger a freshness Job
      manually and confirm normal `PASS` result + no false alert.

## What is NOT in this PR

Tracked under "Future work" in [`README.md`](README.md):

- Webhook (Discord / Slack / Pub-Sub) notification channel + freshness
  wrapper for granular per-source alerts.
- Cloud Monitoring dashboards for pipeline health.
- BQ data-quality monitoring (e.g.
  [`elementary-data`](https://github.com/elementary-data/elementary)).
- Workload Identity Federation for GitHub Actions, replacing the two
  `GCP_SA_KEY_*` secrets.
- Removing legacy Airflow / Snowflake artifacts (`dags/`, root
  `Dockerfile`, `images/`).

## References

- Design doc: [`docs/redesign_proposal.md`](docs/redesign_proposal.md)
  §13.6 (Terraform draft) — this PR is the realized version.
- Branch: `feat/iac` → `main`
