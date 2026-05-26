#!/usr/bin/env bash
#
# Sanity-check the bronze tables after bulk load. Print:
#
#   1. observations: total rows, unique stations, time range, days covered
#   2. observations: sentinel value distribution per numeric column
#   3. observations: per-day row count for the most recent 14 days
#   4. weather_stations: total rows, by ingest_source
#   5. rain_fall_stations: total rows, distinct city/town counts
#
# Read the output before declaring bulk load done. Each check has a one-line
# expectation noted in comments.
#
set -euo pipefail

PROJECT="${GCP_PROJECT_ID:-side-project-staging}"
DATASET="${BQ_DATASET:-weather_raw}"

run_check() {
  local label="$1"
  local sql="$2"
  echo
  echo "==> ${label}"
  bq query \
    --project_id="${PROJECT}" \
    --use_legacy_sql=false \
    --format=pretty \
    "${sql}"
}

# 1. Headline numbers — expect ~3–4 × 10^7 rows, ~700+ unique stations,
#    earliest ≈ 2024-01, latest ≈ today.
#    (Total raw JSON across both buckets ≈ 26 GiB / 70K files; one row per
#    station per snapshot, after dedup on (station_id, measure_at).)
run_check "observations: headline" "
SELECT
  COUNT(*)                              AS total_rows,
  COUNT(DISTINCT station_id)            AS unique_stations,
  COUNT(DISTINCT measure_date)          AS days_covered,
  MIN(measure_at)                       AS earliest,
  MAX(measure_at)                       AS latest
FROM \`${PROJECT}.${DATASET}.observations\`;
"

# 1b. Split by ingest_source — confirms how much came from legacy backfill
#     vs the new crawler. Only meaningful when 01_bulk_load_staging.sh was
#     run with LEGACY_GCS_PATH set; otherwise expect 100% 'new'.
run_check "observations: split by ingest_source" "
SELECT
  ingest_source,
  COUNT(*)                              AS row_count,
  COUNT(DISTINCT station_id)            AS unique_stations,
  MIN(measure_at)                       AS earliest,
  MAX(measure_at)                       AS latest
FROM \`${PROJECT}.${DATASET}.observations\`
GROUP BY ingest_source
ORDER BY ingest_source;
"

# 2. Sentinel distribution — measurement columns are STRING in bronze, so
#    sentinels are matched as strings. Per CWA spec V1.05:
#      'X' / '-99' / '-999'  → instrument-fail / missing (all numeric)
#      '990'                 → calm wind, undefined direction (wind_direction*)
#      'T' / '-98'           → trace / no-rain-6h (precipitation only)
#    Expect non-zero counts on air_pressure, sunshine_duration, uv_index for
#    automatic stations (no sensor) and on wind_direction for calm conditions.
run_check "observations: sentinel distribution per measurement column" "
SELECT
  COUNTIF(air_temperature         IN ('-99', '-999', 'X'))               AS sentinel_air_temperature,
  COUNTIF(air_pressure            IN ('-99', '-999', 'X'))               AS sentinel_air_pressure,
  COUNTIF(relative_humidity       IN ('-99', '-999', 'X'))               AS sentinel_relative_humidity,
  COUNTIF(wind_speed              IN ('-99', '-999', 'X'))               AS sentinel_wind_speed,
  COUNTIF(wind_direction          IN ('-99', '-999', 'X', '990'))        AS sentinel_wind_direction,
  COUNTIF(wind_direction_gust     IN ('-99', '-999', 'X', '990'))        AS sentinel_wind_direction_gust,
  COUNTIF(peak_gust_speed         IN ('-99', '-999', 'X'))               AS sentinel_peak_gust_speed,
  COUNTIF(precipitation           IN ('-99', '-999', 'X', 'T', '-98'))   AS sentinel_precipitation,
  COUNTIF(sunshine_duration_10min IN ('-99', '-999', 'X'))               AS sentinel_sunshine_10min,
  COUNTIF(uv_index                IN ('-99', '-999', 'X'))               AS sentinel_uv_index
FROM \`${PROJECT}.${DATASET}.observations\`;
"

# 3. Recent 14 days row count — flags ingest gaps. Each day should have
#    roughly the same row count (= ~144 snapshots × ~700 stations).
run_check "observations: rows per day, last 14 days" "
SELECT
  measure_date,
  COUNT(*) AS row_count
FROM \`${PROJECT}.${DATASET}.observations\`
WHERE measure_date >= DATE_SUB(CURRENT_DATE('Asia/Taipei'), INTERVAL 14 DAY)
GROUP BY measure_date
ORDER BY measure_date DESC;
"

# 4. weather_stations sanity — manned + unmanned should both appear; total
#    distinct stations should be in the low thousands.
run_check "weather_stations: by ingest_source" "
SELECT
  ingest_source,
  COUNT(*)                                  AS stations,
  COUNTIF(station_status = '現存測站')        AS existing,
  COUNTIF(station_status = '已撤銷')          AS revoked
FROM \`${PROJECT}.${DATASET}.weather_stations\`
GROUP BY ingest_source
ORDER BY ingest_source;
"

# 5. rain_fall_stations sanity — should cover all 22 縣市.
run_check "rain_fall_stations: county / town coverage" "
SELECT
  COUNT(*)                       AS stations,
  COUNT(DISTINCT city_name)      AS distinct_cities,
  COUNT(DISTINCT town_name)      AS distinct_towns
FROM \`${PROJECT}.${DATASET}.rain_fall_stations\`;
"

echo
echo "Verification complete. If all checks look reasonable, run 04_drop_staging.sh."
