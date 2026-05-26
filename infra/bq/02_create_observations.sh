#!/usr/bin/env bash
#
# Flatten observations_staging (and optionally observations_legacy_staging)
# into the bronze observations table. One row per (station, observation
# timestamp), partition by measure_date, cluster by (station_id, station_type).
#
# Sentinel values (-99 / -999) are preserved verbatim — dbt staging cleans
# them in PR #3. station_type classification is inlined here once so dbt does
# not need a macro.
#
# Legacy data handling:
#   - If observations_legacy_staging exists (loaded by 01 when LEGACY_GCS_PATH
#     is set), it is UNION ALL'd in.
#   - Legacy rows carry `ingest_source = 'legacy'` and `ingest_at = NULL`.
#   - On (station_id, measure_at) overlap between legacy and new, the row
#     with non-null ingest_at (i.e. new crawler) wins.
#   - If observations_legacy_staging does not exist, the legacy CTE returns
#     zero rows and the table is built from new staging only.
#
# CREATE OR REPLACE makes this idempotent.
#
set -euo pipefail

PROJECT="${GCP_PROJECT_ID:-side-project-staging}"
DATASET="${BQ_DATASET:-weather_raw}"

# Detect whether legacy staging exists. If not, generate an empty CTE so the
# UNION ALL still parses.
if bq --project_id="${PROJECT}" show --format=none "${DATASET}.observations_legacy_staging" >/dev/null 2>&1; then
  echo "Detected ${DATASET}.observations_legacy_staging — including legacy data."
  LEGACY_CTE="
  legacy AS (
    SELECT
      'legacy' AS ingest_source,
      CAST(NULL AS TIMESTAMP) AS ingest_at,
      station
    FROM \`${PROJECT}.${DATASET}.observations_legacy_staging\`,
    UNNEST(records.Station) AS station
  ),"
  LEGACY_UNION="UNION ALL SELECT * FROM legacy"
else
  echo "No ${DATASET}.observations_legacy_staging — building from new staging only."
  LEGACY_CTE=""
  LEGACY_UNION=""
fi

bq query \
  --project_id="${PROJECT}" \
  --use_legacy_sql=false \
  --max_rows=0 <<SQL
CREATE OR REPLACE TABLE \`${PROJECT}.${DATASET}.observations\`
PARTITION BY measure_date
CLUSTER BY station_id, station_type
OPTIONS (
  description = 'Bronze: one row per (station, observation timestamp). Sentinel values preserved. ingest_source distinguishes new crawler data from legacy backfill.'
)
AS
WITH
  new_data AS (
    SELECT
      'new' AS ingest_source,
      PARSE_TIMESTAMP('%Y-%m-%d_%H_%M', ingested_at) AS ingest_at,
      station
    FROM \`${PROJECT}.${DATASET}.observations_staging\`,
    UNNEST(records.Station) AS station
  ),
  ${LEGACY_CTE}
  combined AS (
    SELECT * FROM new_data
    ${LEGACY_UNION}
  ),
  -- Deduplicate on (station_id, measure_at). When both new and legacy carry
  -- the same observation, prefer the new-crawler row (non-null ingest_at).
  ranked AS (
    SELECT
      *,
      ROW_NUMBER() OVER (
        PARTITION BY station.StationId, station.ObsTime.DateTime
        ORDER BY ingest_at DESC NULLS LAST
      ) AS rn
    FROM combined
  )
SELECT
  station.StationId    AS station_id,
  station.StationName  AS station_name,

  station.WeatherElement.AirTemperature                      AS air_temperature,
  station.WeatherElement.AirPressure                         AS air_pressure,
  station.WeatherElement.RelativeHumidity                    AS relative_humidity,
  station.WeatherElement.WindSpeed                           AS wind_speed,
  station.WeatherElement.WindDirection                       AS wind_direction,
  station.WeatherElement.GustInfo.PeakGustSpeed              AS peak_gust_speed,
  station.WeatherElement.GustInfo.Occurred_at.WindDirection  AS wind_direction_gust,
  station.WeatherElement.Now.Precipitation                   AS precipitation,
  station.WeatherElement.SunshineDuration                    AS sunshine_duration_10min,
  station.WeatherElement.UVIndex                             AS uv_index,

  station.WeatherElement.Weather                             AS weather_status,
  station.WeatherElement.VisibilityDescription               AS visibility,

  station.GeoInfo.CountyName                                 AS county_name,
  station.GeoInfo.CountyCode                                 AS county_code,
  station.GeoInfo.TownName                                   AS town_name,
  station.GeoInfo.TownCode                                   AS town_code,
  station.GeoInfo.StationAltitude                            AS station_altitude,

  -- ObsTime.DateTime is loaded as TIMESTAMP (CWA payload is ISO-8601 with
  -- +08:00 offset, BQ parses to UTC-anchored TIMESTAMP). Calendar date is
  -- extracted in Asia/Taipei so a Taipei-day groups correctly.
  station.ObsTime.DateTime                                   AS measure_at,
  DATE(station.ObsTime.DateTime, 'Asia/Taipei')              AS measure_date,
  ingest_at,
  ingest_source,

  CASE
    WHEN STARTS_WITH(station.StationId, '46') THEN '有人站'
    WHEN STARTS_WITH(station.StationId, 'C0')
      OR STARTS_WITH(station.StationId, 'C1') THEN '自動站'
    ELSE '農業雨量站'
  END AS station_type

FROM ranked
WHERE rn = 1;
SQL

echo "Created ${PROJECT}:${DATASET}.observations. Run 03_create_stations.sh next."
