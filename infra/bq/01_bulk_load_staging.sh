#!/usr/bin/env bash
#
# One-time historical bulk load. Loads staging tables from GCS using either
# explicit JSON schemas (for observations) or autodetect (for station
# metadata, where types are uncontroversial).
#
# Why explicit schema for observations:
#   The CWA O-A0003-001 spec defines a handful of sentinel codes that the
#   API encodes inside numeric fields:
#     'X'   instrument malfunction
#     'T'   trace amount of precipitation
#     '-99' missing / abnormal data
#     '-98' no rain in past 6 hours (precipitation only)
#     '990' calm wind, undefined direction (wind direction only)
#   If we let autodetect infer FLOAT for those columns, the bulk load fails
#   the moment any sensor reports 'X' or 'T'. By declaring measurement
#   columns as STRING in infra/bq/schemas/observations.json, the bronze
#   table preserves the raw CWA value. dbt staging then produces both
#   `<field>_raw` (STRING, original) and `<field>` (FLOAT64, sentinel-cleaned)
#   columns for downstream use.
#
# Tables loaded:
#
#   observations_staging                  weather_data/*.json           explicit schema
#   weather_stations_manned_staging       weather_station/manned/*.json autodetect
#   weather_stations_unmanned_staging     weather_station/unmanned/*.json autodetect
#   rain_fall_stations_staging            rain_fall/*.json              autodetect
#
# (Optional) observations_legacy_staging  ← LEGACY_GCS_PATH              explicit schema
#
# URI glob: BigQuery accepts ONE '*' per URI but that '*' matches '/'. So
# 'weather_data/*.json' recursively matches 'weather_data/2026-05-09/04_53.json'.
# (Opposite of gsutil semantics where '**' would be needed.)
#
# Idempotent: --replace overwrites existing staging on re-run.
#
# Skip the legacy load with: LEGACY_GCS_PATH= ./01_bulk_load_staging.sh
#
set -euo pipefail

PROJECT="${GCP_PROJECT_ID:-side-project-staging}"
DATASET="${BQ_DATASET:-weather_raw}"
BUCKET="${GCS_BUCKET:-side-project-weather-data}"
LEGACY_GCS_PATH="${LEGACY_GCS_PATH-gs://side-project-dev-s3/weather_record/weather_report_10min-*.json}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMAS_DIR="${SCRIPT_DIR}/schemas"

load_with_schema() {
  local table="$1"
  local source="$2"
  local schema_file="$3"

  echo "==> Loading ${PROJECT}:${DATASET}.${table}"
  echo "    from   ${source}"
  echo "    schema ${schema_file}"
  bq load \
    --project_id="${PROJECT}" \
    --source_format=NEWLINE_DELIMITED_JSON \
    --schema="${schema_file}" \
    --replace \
    --max_bad_records=0 \
    --ignore_unknown_values \
    "${DATASET}.${table}" \
    "${source}"
  echo
}

load_with_autodetect() {
  local table="$1"
  local source="$2"

  echo "==> Loading ${PROJECT}:${DATASET}.${table}"
  echo "    from   ${source}"
  echo "    schema autodetect"
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

# Observations (new bucket) — schema-driven.
load_with_schema \
  "observations_staging" \
  "gs://${BUCKET}/weather_data/*.json" \
  "${SCHEMAS_DIR}/observations.json"

# Station metadata — autodetect (no sentinel-encoded numerics here).
load_with_autodetect \
  "weather_stations_manned_staging" \
  "gs://${BUCKET}/weather_station/manned/*.json"

load_with_autodetect \
  "weather_stations_unmanned_staging" \
  "gs://${BUCKET}/weather_station/unmanned/*.json"

load_with_autodetect \
  "rain_fall_stations_staging" \
  "gs://${BUCKET}/rain_fall/*.json"

# Optional: legacy s3-bucket observations, same schema as new.
if [ -n "${LEGACY_GCS_PATH}" ]; then
  load_with_schema \
    "observations_legacy_staging" \
    "${LEGACY_GCS_PATH}" \
    "${SCHEMAS_DIR}/observations.json"
else
  echo "Skipping legacy load (LEGACY_GCS_PATH unset)."
fi

echo "All staging tables loaded. Run 02_create_observations.sh next."
