#!/usr/bin/env bash
#
# Create the bronze BigQuery dataset. Idempotent: skips if the dataset already
# exists.
#
set -euo pipefail

PROJECT="${GCP_PROJECT_ID:-side-project-weather}"
DATASET="${BQ_DATASET:-weather_raw}"
LOCATION="${BQ_LOCATION:-asia-east1}"

if bq --project_id="${PROJECT}" show --format=prettyjson "${DATASET}" >/dev/null 2>&1; then
  echo "Dataset ${PROJECT}:${DATASET} already exists. Skipping."
else
  echo "Creating dataset ${PROJECT}:${DATASET} in ${LOCATION}..."
  bq mk \
    --project_id="${PROJECT}" \
    --dataset \
    --location="${LOCATION}" \
    --description="Bronze layer for weather observations and station metadata. See infra/bq/README.md." \
    "${DATASET}"
  echo "Done."
fi
