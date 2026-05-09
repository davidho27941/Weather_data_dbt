#!/usr/bin/env bash
#
# Drop the four *_staging tables once 02 / 03 have built the bronze tables and
# verify.sh has confirmed the row counts. Staging tables are intermediate
# build artifacts and should not linger.
#
# Re-run safe: DROP IF EXISTS.
#
set -euo pipefail

PROJECT="${GCP_PROJECT_ID:-side-project-weather}"
DATASET="${BQ_DATASET:-weather_raw}"

drop_table() {
  local table="$1"
  echo "Dropping ${PROJECT}:${DATASET}.${table} (if exists)..."
  bq query \
    --project_id="${PROJECT}" \
    --use_legacy_sql=false \
    --max_rows=0 \
    "DROP TABLE IF EXISTS \`${PROJECT}.${DATASET}.${table}\`"
}

drop_table "observations_staging"
drop_table "observations_legacy_staging"
drop_table "weather_stations_manned_staging"
drop_table "weather_stations_unmanned_staging"
drop_table "rain_fall_stations_staging"

echo "Cleanup done."
