#!/usr/bin/env bash
#
# Create or update the two Cloud Run Jobs for dbt:
#
#   dbt-daily-build         daily 02:30 Asia/Taipei  →  dbt build --target stg
#   dbt-hourly-freshness    every hour              →  dbt source freshness --target stg
#
# Cloud Scheduler triggers are attached separately (Console or Terraform).
# This script only manages the Job definitions themselves.
#
# Idempotent: uses `gcloud run jobs deploy` which creates if missing,
# updates if present.
#
# Usage:
#   ./deploy_jobs.sh [TAG]
#
# Defaults match build_and_push.sh.
#
set -euo pipefail

TAG="${1:-$(git rev-parse --short HEAD 2>/dev/null || echo latest)}"
PROJECT="${GCP_PROJECT_ID:-side-project-staging}"
REGION="${BQ_LOCATION:-asia-east1}"
AR_REPO="${AR_REPO:-dbt}"
SA_EMAIL="${DBT_SA_EMAIL:-dbt-runner@${PROJECT}.iam.gserviceaccount.com}"

IMAGE="${REGION}-docker.pkg.dev/${PROJECT}/${AR_REPO}/dbt-weather:${TAG}"

deploy_job() {
  local name="$1"
  shift  # remaining args = dbt subcommand args

  local args_csv
  args_csv="$(printf '%s,' "$@" | sed 's/,$//')"

  echo "==> Deploying Cloud Run Job ${name}"
  echo "    image=${IMAGE}"
  echo "    args=${args_csv}"

  gcloud run jobs deploy "${name}" \
    --project="${PROJECT}" \
    --region="${REGION}" \
    --image="${IMAGE}" \
    --service-account="${SA_EMAIL}" \
    --set-env-vars="DBT_TARGET=stg,GCP_PROJECT_ID=${PROJECT},BRONZE_PROJECT=${PROJECT}" \
    --max-retries=1 \
    --task-timeout=1800s \
    --cpu=2 \
    --memory=2Gi \
    --args="${args_csv}"

  echo
}

# 1. Daily dbt build
deploy_job "dbt-daily-build" "build"

# 2. Hourly source freshness
deploy_job "dbt-hourly-freshness" "source" "freshness"

cat <<EOF

Both Cloud Run Jobs deployed.

Next steps (manual, see infra/dbt/README.md):
  - Attach a Cloud Scheduler trigger for each Job.
    daily build:        cron '30 2 * * *' time-zone Asia/Taipei
    hourly freshness:   cron '0 * * * *' time-zone Asia/Taipei
  - Verify SA permissions:
    bigquery.dataEditor on weather_dev/staging/intermediate/marts datasets
    bigquery.dataViewer on weather_raw
    bigquery.user       on the project

Test ad-hoc:
  gcloud run jobs execute dbt-daily-build --region=${REGION}
  gcloud run jobs execute dbt-hourly-freshness --region=${REGION}
EOF
