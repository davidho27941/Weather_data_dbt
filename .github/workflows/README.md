# GitHub Actions setup

Four workflows live here:

| Workflow | Trigger | What it does |
|---|---|---|
| [`dbt_ci.yml`](dbt_ci.yml) | PRs touching `weather_data_dbt/**` or `infra/dbt/**` | `dbt deps` + `dbt parse` + `dbt build --target ci --full-refresh --vars '{ci_sample_days: 7}'` against `weather_ci_*` |
| [`dbt_cd.yml`](dbt_cd.yml) | Push to `main` touching `weather_data_dbt/**` or `infra/dbt/**` | Build + push image to Artifact Registry, then `gcloud run jobs update` on `dbt-weekly-build` and `dbt-hourly-freshness` |
| [`bq_cd.yml`](bq_cd.yml) | Push to `main` touching `infra/bq/**` | Build + push the `bronze-loader` image, then `gcloud run jobs update` on `bronze-daily-load` |
| [`build_dbt_docs.yml`](build_dbt_docs.yml) | Push to `main` touching `weather_data_dbt/**` | `dbt docs generate` + publish to GitHub Pages |

## One-time GCP setup

You need two service accounts and one Artifact Registry repo (already
documented in [`../../infra/dbt/README.md`](../../infra/dbt/README.md) for
the dbt runtime SA — re-listed here so this doc stands alone).

### 1. Artifact Registry repo

```bash
gcloud artifacts repositories create dbt \
  --repository-format=docker \
  --location=asia-east1 \
  --project=side-project-staging
```

### 2. Runtime SA (`dbt-runner@…`)

This is the SA the Cloud Run Jobs run as — it must exist *before* §4
binds `roles/iam.serviceAccountUser` on it. Also documented in
[`../../infra/dbt/README.md`](../../infra/dbt/README.md); recopied here so
the GHA setup is self-contained.

```bash
PROJECT=side-project-staging
SA_RUNNER=dbt-runner@${PROJECT}.iam.gserviceaccount.com

gcloud iam service-accounts create dbt-runner \
  --project="${PROJECT}" \
  --display-name="dbt Cloud Run Job runtime"

gcloud projects add-iam-policy-binding "${PROJECT}" \
  --member="serviceAccount:${SA_RUNNER}" \
  --role="roles/bigquery.user"

# Dataset-level grants. The three weather_{staging,intermediate,marts}
# datasets are created by the first `dbt build` from a workstation; if
# they don't exist yet, `bq add-iam-policy-binding` will fail with NOT_FOUND.
# Either run a workstation `dbt build --target stg` once, or pre-create
# the empty datasets:
#   for DS in staging intermediate marts; do
#     bq mk --location=asia-east1 --dataset "${PROJECT}:weather_${DS}"
#   done
# Dataset-level grants via SQL DCL. `bq add-iam-policy-binding` would
# require allowlisting on the project; GRANT does not.
for DS in weather_staging weather_intermediate weather_marts; do
  bq query --use_legacy_sql=false --location=asia-east1 "
GRANT \`roles/bigquery.dataEditor\`
ON SCHEMA \`${PROJECT}.${DS}\`
TO 'serviceAccount:${SA_RUNNER}'
"
done

bq query --use_legacy_sql=false --location=asia-east1 "
GRANT \`roles/bigquery.dataViewer\`
ON SCHEMA \`${PROJECT}.weather_raw\`
TO 'serviceAccount:${SA_RUNNER}'
"
```

### 2b. Bronze runtime SA (`bronze-loader@…`)

Runtime SA for the `bronze-daily-load` Cloud Run Job. Permissions are
disjoint from `dbt-runner@…` — bronze writes to `weather_raw` and reads
from GCS, dbt writes to `weather_{staging,intermediate,marts}` and reads
`weather_raw`. Setup steps mirror §2 (also documented in
[`../../infra/bq/README.md`](../../infra/bq/README.md)):

```bash
PROJECT=side-project-staging
SA_BRONZE=bronze-loader@${PROJECT}.iam.gserviceaccount.com
BUCKET=side-project-weather-data

gcloud iam service-accounts create bronze-loader \
  --project="${PROJECT}" \
  --display-name="bronze daily-load Cloud Run Job runtime"

gcloud projects add-iam-policy-binding "${PROJECT}" \
  --member="serviceAccount:${SA_BRONZE}" \
  --role="roles/bigquery.user"

# Dataset-level grant via SQL DCL. `bq add-iam-policy-binding` would also
# work in theory but requires allowlisting on the project — GRANT does not.
bq query --use_legacy_sql=false --location=asia-east1 "
GRANT \`roles/bigquery.dataEditor\`
ON SCHEMA \`${PROJECT}.weather_raw\`
TO 'serviceAccount:${SA_BRONZE}'
"

gcloud storage buckets add-iam-policy-binding "gs://${BUCKET}" \
  --member="serviceAccount:${SA_BRONZE}" \
  --role="roles/storage.objectViewer"
```

### 3. CI service account (`gha-ci@…`)

Used by `dbt_ci.yml` and `build_dbt_docs.yml`. Permissions kept minimal:

```bash
PROJECT=side-project-staging
SA_CI=gha-ci@${PROJECT}.iam.gserviceaccount.com

gcloud iam service-accounts create gha-ci \
  --project="${PROJECT}" \
  --display-name="GitHub Actions dbt CI"

# BQ project-level user (lets dbt list datasets, run queries, create the
# weather_ci_* datasets it writes to).
gcloud projects add-iam-policy-binding "${PROJECT}" \
  --member="serviceAccount:${SA_CI}" \
  --role="roles/bigquery.user"

# Read bronze.
gcloud projects add-iam-policy-binding "${PROJECT}" \
  --member="serviceAccount:${SA_CI}" \
  --role="roles/bigquery.dataViewer" \
  --condition='expression=resource.name.startsWith("projects/'"${PROJECT}"'/datasets/weather_raw"),title=weather_raw_only'
# (drop the --condition if conditional bindings aren't enabled on the project)

# Write to weather_ci_* (created on demand by dbt; the project-level
# bigquery.user role is what allows dataset creation, then the SA is the
# owner of what it created so writes work without further bindings.)
```

Generate a key (rotate yearly; this is the trade-off the project accepted
in lieu of Workload Identity Federation):

```bash
gcloud iam service-accounts keys create gha-ci-key.json \
  --iam-account="${SA_CI}"
```

Add as repo secret `GCP_SA_KEY_CI` — paste the entire JSON file contents.
Delete the local copy after.

### 4. CD service account (`gha-cd@…`)

Used by both `dbt_cd.yml` and `bq_cd.yml`. Needs to push images and roll
all three Cloud Run Jobs:

> **Prerequisite**: §2 + §2b must have run (so `dbt-runner@…` and
> `bronze-loader@…` exist for the `iam.serviceAccountUser` bindings
> below), and the three Cloud Run Jobs must already exist before the CD
> workflows run — `gcloud run jobs update` only changes the image tag in
> place. Run
> [`../../infra/dbt/deploy_jobs.sh`](../../infra/dbt/deploy_jobs.sh) and
> [`../../infra/bq/deploy_jobs.sh`](../../infra/bq/deploy_jobs.sh) once
> from a workstation to create them.


```bash
SA_CD=gha-cd@${PROJECT}.iam.gserviceaccount.com
SA_DBT_RUNNER=dbt-runner@${PROJECT}.iam.gserviceaccount.com
SA_BRONZE=bronze-loader@${PROJECT}.iam.gserviceaccount.com

gcloud iam service-accounts create gha-cd \
  --project="${PROJECT}" \
  --display-name="GitHub Actions CD (dbt + bronze)"

# Push to Artifact Registry (single repo `dbt` holds both dbt-weather and
# bronze-loader images).
gcloud artifacts repositories add-iam-policy-binding dbt \
  --location=asia-east1 \
  --project="${PROJECT}" \
  --member="serviceAccount:${SA_CD}" \
  --role="roles/artifactregistry.writer"

# Update Cloud Run Jobs (image tag only, not full deploy).
gcloud projects add-iam-policy-binding "${PROJECT}" \
  --member="serviceAccount:${SA_CD}" \
  --role="roles/run.developer"

# Allow CD to "act as" both runtime SAs when updating jobs.
for SA in "${SA_DBT_RUNNER}" "${SA_BRONZE}"; do
  gcloud iam service-accounts add-iam-policy-binding "${SA}" \
    --member="serviceAccount:${SA_CD}" \
    --role="roles/iam.serviceAccountUser"
done
```

Generate key, add as repo secret `GCP_SA_KEY_CD`:

```bash
gcloud iam service-accounts keys create gha-cd-key.json \
  --iam-account="${SA_CD}"
```

## GitHub repo configuration

### Secrets (Settings → Secrets and variables → Actions → Secrets)

| Name | Used by | Value |
|---|---|---|
| `GCP_SA_KEY_CI` | `dbt_ci.yml`, `build_dbt_docs.yml` | JSON key contents for `gha-ci@…` |
| `GCP_SA_KEY_CD` | `dbt_cd.yml`, `bq_cd.yml` | JSON key contents for `gha-cd@…` |


-----

### Variables (Settings → Secrets and variables → Actions → Variables)

Optional — workflows fall back to staging defaults when unset:

| Name | Default | Notes |
|---|---|---|
| `GCP_PROJECT_ID` | `side-project-staging` | Override when prod stands up its own project |
| `BQ_LOCATION` | `asia-east1` | BigQuery + Artifact Registry region |
| `AR_REPO` | `dbt` | Artifact Registry repo name |
| `DBT_RUNNER_SA` | `dbt-runner@side-project-staging.iam.gserviceaccount.com` | Runtime SA bound to the Cloud Run Jobs |

### GitHub Pages

`build_dbt_docs.yml` deploys to GitHub Pages via the
`actions/deploy-pages@v4` action. Enable Pages once under
Settings → Pages → Source = "GitHub Actions".

## Cost notes

- `dbt_ci.yml` builds a 7-day bronze subsample on every PR. With ~70K
  observation rows/day that is ~half a million rows through staging →
  intermediate → marts, well under a dollar per run on BQ.
- `dbt_cd.yml` only runs on `main` pushes that touch dbt or its image.
  Image push is a few hundred MB; Cloud Run Job updates are free.
- `build_dbt_docs.yml` issues no SQL queries — `dbt docs generate` reads
  schema metadata via the BQ INFORMATION_SCHEMA, which is free.

## Migration path (later)

Switch from SA keys to Workload Identity Federation when ready:

1. Create a WIF pool + provider for `https://token.actions.githubusercontent.com`.
2. Add `roles/iam.workloadIdentityUser` to the two SAs from
   `principal://iam.googleapis.com/.../attribute.repository/<owner>/<repo>`.
3. In each workflow, swap `credentials_json:` for
   `workload_identity_provider:` and `service_account:`.
4. Delete the SA keys and remove the `GCP_SA_KEY_*` secrets.

The workflows already declare `id-token: write` permission, so the only
file changes are the two `auth@v2` step inputs.
