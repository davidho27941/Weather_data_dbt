# Terraform — pipeline infrastructure

Single root module that manages everything PR #3 + PR #4 created via
shell scripts:

| Resource | TF file |
|---|---|
| 5 service accounts (`dbt-runner`, `bronze-loader`, `scheduler-invoker`, `gha-ci`, `gha-cd`) | [`service_accounts.tf`](service_accounts.tf) |
| Artifact Registry repo `dbt` | [`artifact_registry.tf`](artifact_registry.tf) |
| Project / repo / bucket / act-as IAM | [`iam.tf`](iam.tf) |
| Three managed BQ datasets (`weather_staging`, `weather_intermediate`, `weather_marts`) + dataset-level IAM (incl. `weather_raw` viewer/editor grants) | [`bigquery.tf`](bigquery.tf) |
| Three Cloud Run Jobs (`bronze-daily-load`, `dbt-weekly-build`, `dbt-hourly-freshness`) | [`cloud_run_jobs.tf`](cloud_run_jobs.tf) |
| Three Cloud Scheduler triggers + invoker IAM | [`cloud_scheduler.tf`](cloud_scheduler.tf) |
| Email notification channel + Cloud Run Job failure alert policy | [`monitoring.tf`](monitoring.tf) |

**Out of scope** (intentional):

- GHA repo secrets / variables — kept manual to avoid putting a GitHub
  PAT in tfstate.
- Service account JSON keys for `gha-ci` / `gha-cd` — keys never live in
  tfstate. Continue creating them manually per
  [`../.github/workflows/README.md`](../.github/workflows/README.md).
- `weather_raw` dataset itself — only IAM is TF-managed. The dataset is
  owned by the bronze layer's bulk-load history.
- GCS bucket `side-project-weather-data` itself — only IAM is TF-managed.
  The bucket is crawler-owned.
- `weather_dev_*` and `weather_ci_*` datasets — created on demand by
  dbt and ephemeral / per-developer.

## State backend

Remote state in GCS bucket `weather-pipeline-tfstate`, prefix
`weather-pipeline`. Versioning is enabled — every apply mutates state,
and a corrupted apply needs to roll back to a prior generation.

## One-time bootstrap

```bash
# 1. Create the state bucket (idempotent; no-op if it exists)
./bootstrap/create_state_bucket.sh

# 2. Set up your tfvars
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars                # at minimum, set alert_email

# 3. Init Terraform against the GCS backend
terraform init

# 4. Pull existing GCP resources into state (PR #3 + PR #4 inventory).
#    Re-runnable — already-imported resources are skipped.
ALERT_EMAIL=davidho.prime@gmail.com ./import.sh

# 5. Verify drift between TF spec and reality
terraform plan
```

A clean import should produce a `terraform plan` output that's near
zero — anything more than IAM ordering noise is a real divergence
between the TF spec and what's deployed. Adjust the `.tf` files
(or the deployed resource) until plan is clean **before** any
`terraform apply`.

## Day-2 ops

```bash
terraform plan -out=tfplan       # review
terraform apply tfplan           # apply only what plan showed
terraform output                 # SAs, jobs, schedulers, channel/policy IDs
```

Image tags on the three Cloud Run Jobs are intentionally outside TF
control (`lifecycle.ignore_changes` on `template[0].template[0].containers[0].image`).
GHA's `dbt_cd.yml` and `bq_cd.yml` workflows roll those forward; TF
shouldn't fight them.

Schedule cadences are inputs (`var.schedules`) — change a cron and
re-apply, no other surface needs updating.

Channel verification status is similarly excluded from drift; clicking
the verify link out-of-band is what flips it from `UNVERIFIED` to
`VERIFIED`, not Terraform.

## What you need on your gcloud account

To run apply locally as your individual user, the following project-level
roles cover the resource set:

- `roles/iam.serviceAccountAdmin`
- `roles/resourcemanager.projectIamAdmin`
- `roles/artifactregistry.admin`
- `roles/bigquery.admin`
- `roles/run.admin`
- `roles/cloudscheduler.admin`
- `roles/monitoring.admin`
- `roles/storage.admin` (only for the GCS state bucket; can be scoped to that bucket)

For prod, swap your account for a TF-runner SA with the same roles
scoped to the prod project, and run apply from CI rather than a laptop.

## Layout

```
terraform/
├── README.md                       ← this file
├── versions.tf                     ← required_version + provider versions
├── backend.tf                      ← GCS remote state config
├── providers.tf                    ← google provider
├── variables.tf                    ← inputs (project, region, alert_email, schedules)
├── terraform.tfvars.example        ← copy to terraform.tfvars (gitignored)
├── locals.tf                       ← computed values shared across files
├── service_accounts.tf
├── artifact_registry.tf
├── iam.tf
├── bigquery.tf
├── cloud_run_jobs.tf
├── cloud_scheduler.tf
├── monitoring.tf
├── outputs.tf
├── bootstrap/
│   └── create_state_bucket.sh      ← one-time GCS state bucket setup
└── import.sh                       ← terraform import for the existing inventory
```
