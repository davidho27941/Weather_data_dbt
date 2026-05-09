#!/usr/bin/env bash
#
# Optional: bulk-load legacy weather observation JSON that lives in a
# separate GCS bucket with a different path layout.
#
#   gs://side-project-dev-s3/weather_record/weather_report_10min-{date}_{hhmm}.json
#
# These files predate the current crawler. Inner JSON schema is assumed to
# match (same CWA O-A0003-001 endpoint), but the crawler-injected
# `ingested_at` field is not present, so legacy rows will carry
# `ingest_at = NULL` after the bronze CTAS in 02_create_observations.sh.
#
# Run AFTER 01_bulk_load_staging.sh and BEFORE 02_create_observations.sh.
# Skip this entirely if you have no legacy data to import.
#
# Idempotent: --replace overwrites the staging table on re-run.
#
set -euo pipefail

PROJECT="${GCP_PROJECT_ID:-side-project-weather}"
DATASET="${BQ_DATASET:-weather_raw}"
LEGACY_GCS_PATH="${LEGACY_GCS_PATH:-gs://side-project-dev-s3/weather_record/weather_report_10min-*.json}"

echo "==> Loading ${PROJECT}:${DATASET}.observations_legacy_staging"
echo "    from ${LEGACY_GCS_PATH}"

bq load \
  --project_id="${PROJECT}" \
  --source_format=NEWLINE_DELIMITED_JSON \
  --autodetect \
  --replace \
  --max_bad_records=0 \
  "${DATASET}.observations_legacy_staging" \
  "${LEGACY_GCS_PATH}"

echo "Done. Run 02_create_observations.sh next."
