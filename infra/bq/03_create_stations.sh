#!/usr/bin/env bash
#
# Build two station bronze tables:
#
#   weather_stations    — manned + unmanned merged, one row per station,
#                         keeping the latest snapshot per StationID.
#   rain_fall_stations  — agricultural rain-fall stations, one row per station,
#                         latest snapshot.
#
# Both source tables (manned/unmanned/rain_fall) accumulate daily snapshots in
# GCS, so we deduplicate by StationID ordering on ingest_at desc.
#
# Idempotent via CREATE OR REPLACE TABLE.
#
set -euo pipefail

PROJECT="${GCP_PROJECT_ID:-side-project-weather}"
DATASET="${BQ_DATASET:-weather_raw}"

echo "==> Creating ${PROJECT}:${DATASET}.weather_stations"

bq query \
  --project_id="${PROJECT}" \
  --use_legacy_sql=false \
  --max_rows=0 \
"$(cat <<SQL
CREATE OR REPLACE TABLE \`${PROJECT}.${DATASET}.weather_stations\`
CLUSTER BY station_id
OPTIONS (
  description = 'Bronze: latest snapshot per CWA weather station (manned + unmanned union).'
)
AS
WITH manned AS (
  SELECT
    'manned' AS ingest_source,
    PARSE_TIMESTAMP('%Y-%m-%d_%H_%M', ingested_at) AS ingest_at,
    station
  FROM \`${PROJECT}.${DATASET}.weather_stations_manned_staging\`,
  UNNEST(records.data.stationStatus.station) AS station
),
unmanned AS (
  SELECT
    'unmanned' AS ingest_source,
    PARSE_TIMESTAMP('%Y-%m-%d_%H_%M', ingested_at) AS ingest_at,
    station
  FROM \`${PROJECT}.${DATASET}.weather_stations_unmanned_staging\`,
  UNNEST(records.data.stationStatus.station) AS station
),
combined AS (
  SELECT * FROM manned
  UNION ALL
  SELECT * FROM unmanned
),
latest AS (
  SELECT * EXCEPT(rn) FROM (
    SELECT
      *,
      ROW_NUMBER() OVER (
        PARTITION BY station.StationID
        ORDER BY ingest_at DESC
      ) AS rn
    FROM combined
  )
  WHERE rn = 1
)
SELECT
  station.StationID                                                  AS station_id,
  NULLIF(station.OriginalStationID, '')                              AS original_station_id,
  NULLIF(station.NewStationID, '')                                   AS new_station_id,
  station.status                                                     AS station_status,
  station.StationName                                                AS station_name,
  station.StationNameEN                                              AS station_name_en,
  station.CountyName                                                 AS county_name,
  station.Location                                                   AS location,
  NULLIF(station.Notes, '')                                          AS notes,
  SAFE_CAST(station.StationAltitude  AS FLOAT64)                     AS station_altitude,
  SAFE_CAST(station.StationLongitude AS FLOAT64)                     AS station_longitude,
  SAFE_CAST(station.StationLatitude  AS FLOAT64)                     AS station_latitude,
  SAFE.PARSE_DATE('%Y-%m-%d', NULLIF(station.StationStartDate, ''))  AS start_at,
  SAFE.PARSE_DATE('%Y-%m-%d', NULLIF(station.StationEndDate, ''))    AS end_at,
  ingest_source,
  ingest_at
FROM latest;
SQL
)"

echo "==> Creating ${PROJECT}:${DATASET}.rain_fall_stations"

bq query \
  --project_id="${PROJECT}" \
  --use_legacy_sql=false \
  --max_rows=0 \
"$(cat <<SQL
CREATE OR REPLACE TABLE \`${PROJECT}.${DATASET}.rain_fall_stations\`
CLUSTER BY station_id
OPTIONS (
  description = 'Bronze: latest snapshot per agricultural rain-fall station.'
)
AS
WITH ingested AS (
  SELECT
    PARSE_TIMESTAMP('%Y-%m-%d_%H_%M', ingested_at) AS ingest_at,
    station
  FROM \`${PROJECT}.${DATASET}.rain_fall_stations_staging\`,
  UNNEST(Data) AS station
),
latest AS (
  SELECT * EXCEPT(rn) FROM (
    SELECT
      *,
      ROW_NUMBER() OVER (
        PARTITION BY station.Station_ID
        ORDER BY ingest_at DESC
      ) AS rn
    FROM ingested
  )
  WHERE rn = 1
)
SELECT
  station.Station_ID                                  AS station_id,
  station.Station_name                                AS station_name,
  station.CITY_SN                                     AS city_code,
  station.CITY                                        AS city_name,
  station.TOWN_SN                                     AS town_code,
  station.TOWN                                        AS town_name,
  SAFE_CAST(station.Station_Latitude  AS FLOAT64)     AS station_latitude,
  SAFE_CAST(station.Station_Longitude AS FLOAT64)     AS station_longitude,
  ingest_at
FROM latest;
SQL
)"

echo "Both station tables created. Run verify.sh next, then 04_drop_staging.sh."
