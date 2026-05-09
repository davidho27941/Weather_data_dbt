#!/usr/bin/env bash
#
# One-time historical bulk load. Loads four staging tables that preserve the
# raw nested JSON structure from GCS:
#
#   - observations_staging                  ← weather_data/*/*.json
#   - weather_stations_manned_staging       ← weather_station/manned/*/*.json
#   - weather_stations_unmanned_staging     ← weather_station/unmanned/*/*.json
#   - rain_fall_stations_staging            ← rain_fall/*/*.json
#
# Step 02 / 03 then UNNEST these into the partitioned + clustered bronze tables.
#
# Idempotent: --replace overwrites existing staging on re-run. Each crawler
# JSON file is one compact line, so NEWLINE_DELIMITED_JSON works directly.
#
set -euo pipefail

PROJECT="${GCP_PROJECT_ID:-side-project-weather}"
DATASET="${BQ_DATASET:-weather_raw}"
BUCKET="${GCS_BUCKET:-side-project-weather-data}"

load_staging() {
  local table="$1"
  local source="$2"

  echo "==> Loading ${PROJECT}:${DATASET}.${table}"
  echo "    from ${source}"
  bq load \
    --project_id="${PROJECT}" \
    --source_format=NEWLINE_DELIMITED_JSON \
    --autodetect \
    --replace \
    --max_bad_records=0 \
    "${DATASET}.${table}" \
    "${source}"
  echo
}

load_staging \
  "observations_staging" \
  "gs://${BUCKET}/weather_data/*/*.json"

load_staging \
  "weather_stations_manned_staging" \
  "gs://${BUCKET}/weather_station/manned/*/*.json"

load_staging \
  "weather_stations_unmanned_staging" \
  "gs://${BUCKET}/weather_station/unmanned/*/*.json"

load_staging \
  "rain_fall_stations_staging" \
  "gs://${BUCKET}/rain_fall/*/*.json"

echo "All staging tables loaded. Run 02_create_observations.sh next."
