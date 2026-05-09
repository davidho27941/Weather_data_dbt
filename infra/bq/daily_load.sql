-- ============================================================================
-- Daily ongoing bronze load for weather observations.
--
-- Loads one day of crawler JSON from GCS into a transient daily staging table,
-- then MERGEs into the partitioned bronze observations table, then drops the
-- daily staging table. Idempotent on (station_id, measure_at).
--
-- Parameter:
--   @target_date  STRING  YYYY-MM-DD. If empty/null, defaults to yesterday
--                         in Asia/Taipei.
--
-- Invocation:
--   1. Ad-hoc via bq CLI (see daily_load.sh wrapper):
--      bq query --use_legacy_sql=false --max_rows=0 \
--        --parameter='target_date:STRING:' \
--        < daily_load.sql
--
--   2. BigQuery Scheduled Query (deploy via Console or Terraform):
--      - Paste this entire SQL into the Schedule editor.
--      - Configure parameter `target_date` of type STRING with value '' (empty).
--      - Set schedule cron `0 2 * * *` time-zone `Asia/Taipei`.
--      - Use a service account with bigquery.dataEditor on weather_raw and
--        storage.objectViewer on the source GCS bucket.
--
-- Bucket / project / dataset are hard-coded here because BQ scripting does
-- not support `${VAR}` shell-style interpolation. Edit the constants at the
-- top of the script if your environment differs.
-- ============================================================================

DECLARE project_id STRING DEFAULT 'side-project-weather';
DECLARE dataset    STRING DEFAULT 'weather_raw';
DECLARE bucket     STRING DEFAULT 'side-project-weather-data';

DECLARE target_date STRING;
SET target_date = IFNULL(
  NULLIF(@target_date, ''),
  FORMAT_DATE('%Y-%m-%d', DATE_SUB(CURRENT_DATE('Asia/Taipei'), INTERVAL 1 DAY))
);

-- ----------------------------------------------------------------------------
-- 1. Load the day's GCS files into a transient staging table.
-- ----------------------------------------------------------------------------
EXECUTE IMMEDIATE FORMAT("""
  LOAD DATA OVERWRITE `%s.%s.observations_daily_staging`
  FROM FILES (
    format = 'JSON',
    uris   = ['gs://%s/weather_data/%s/*.json']
  );
""", project_id, dataset, bucket, target_date);

-- ----------------------------------------------------------------------------
-- 2. MERGE flattened observations into the bronze table.
--    Idempotent on (station_id, measure_at). Late-arriving snapshots from
--    re-runs of the same day collapse into a single row.
-- ----------------------------------------------------------------------------
EXECUTE IMMEDIATE FORMAT("""
  MERGE `%s.%s.observations` AS target
  USING (
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

      TIMESTAMP(station.ObsTime.DateTime, 'Asia/Taipei')         AS measure_at,
      DATE(station.ObsTime.DateTime, 'Asia/Taipei')              AS measure_date,
      PARSE_TIMESTAMP('%%Y-%%m-%%d_%%H_%%M', ingested_at)        AS ingest_at,
      'new'                                                      AS ingest_source,

      CASE
        WHEN STARTS_WITH(station.StationId, '46') THEN '有人站'
        WHEN STARTS_WITH(station.StationId, 'C0')
          OR STARTS_WITH(station.StationId, 'C1') THEN '自動站'
        ELSE '農業雨量站'
      END AS station_type
    FROM `%s.%s.observations_daily_staging`,
    UNNEST(records.Station) AS station
  ) AS source
  ON  target.station_id = source.station_id
  AND target.measure_at = source.measure_at
  WHEN MATCHED THEN UPDATE SET
    station_name             = source.station_name,
    air_temperature          = source.air_temperature,
    air_pressure             = source.air_pressure,
    relative_humidity        = source.relative_humidity,
    wind_speed               = source.wind_speed,
    wind_direction           = source.wind_direction,
    peak_gust_speed          = source.peak_gust_speed,
    wind_direction_gust      = source.wind_direction_gust,
    precipitation            = source.precipitation,
    sunshine_duration_10min  = source.sunshine_duration_10min,
    uv_index                 = source.uv_index,
    weather_status           = source.weather_status,
    visibility               = source.visibility,
    county_name              = source.county_name,
    county_code              = source.county_code,
    town_name                = source.town_name,
    town_code                = source.town_code,
    station_altitude         = source.station_altitude,
    measure_date             = source.measure_date,
    ingest_at                = source.ingest_at,
    ingest_source            = source.ingest_source,
    station_type             = source.station_type
  WHEN NOT MATCHED THEN INSERT ROW;
""", project_id, dataset, project_id, dataset);

-- ----------------------------------------------------------------------------
-- 3. Drop the daily staging table — it is a build artifact, not data.
-- ----------------------------------------------------------------------------
EXECUTE IMMEDIATE FORMAT("""
  DROP TABLE IF EXISTS `%s.%s.observations_daily_staging`;
""", project_id, dataset);
