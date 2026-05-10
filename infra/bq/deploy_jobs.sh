#!/usr/bin/env bash
#
# Create or update the Cloud Run Job for the bronze daily load:
#
#   bronze-daily-load    daily 02:00 Asia/Taipei  →  bq query < daily_load.sql
#
# Cloud Scheduler triggers are attached separately (Console, gcloud, or
# Terraform). This script only manages the Job definition itself.
#
# Idempotent: uses `gcloud run jobs deploy` which creates if missing,
# updates if present.
#
# Usage:
#   ./deploy_jobs.sh [TAG]
#
set -euo pipefail

TAG="${1:-$(git rev-parse --short HEAD 2>/dev/null || echo latest)}"
PROJECT="${GCP_PROJECT_ID:-side-project-staging}"
REGION="${BQ_LOCATION:-asia-east1}"
AR_REPO="${AR_REPO:-dbt}"
SA_EMAIL="${BRONZE_SA_EMAIL:-bronze-loader@${PROJECT}.iam.gserviceaccount.com}"

IMAGE="${REGION}-docker.pkg.dev/${PROJECT}/${AR_REPO}/bronze-loader:${TAG}"

echo "==> Deploying Cloud Run Job bronze-daily-load"
echo "    image=${IMAGE}"
echo "    service-account=${SA_EMAIL}"

gcloud run jobs deploy "bronze-daily-load" \
  --project="${PROJECT}" \
  --region="${REGION}" \
  --image="${IMAGE}" \
  --service-account="${SA_EMAIL}" \
  --set-env-vars="GCP_PROJECT_ID=${PROJECT},BQ_LOCATION=${REGION}" \
  --max-retries=2 \
  --task-timeout=900s \
  --cpu=1 \
  --memory=512Mi

cat <<EOF

Cloud Run Job bronze-daily-load deployed.

Next steps (manual, see infra/bq/README.md):
  - Attach a Cloud Scheduler trigger:
      cron '0 2 * * *' time-zone Asia/Taipei
  - Verify SA permissions:
      bigquery.dataEditor on weather_raw
      bigquery.user       on the project
      storage.objectViewer on gs://side-project-weather-data

Test ad-hoc:
  gcloud run jobs execute bronze-daily-load --region=${REGION}
EOF
