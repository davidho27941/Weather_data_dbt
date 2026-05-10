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
--   2. Production: Cloud Run Job `bronze-daily-load`, scheduled by Cloud
--      Scheduler at cron `0 2 * * *` Asia/Taipei. The container image
--      built from infra/bq/Dockerfile bakes in this SQL plus daily_load.sh,
--      and runs as the `bronze-loader@…` service account. See
--      [infra/bq/README.md] for deployment + IAM steps.
--
-- Bucket / project / dataset are hard-coded here because BQ scripting does
-- not support `${VAR}` shell-style interpolation. Edit the constants at the
-- top of the script if your environment differs.
-- ============================================================================

DECLARE project_id STRING DEFAULT 'side-project-staging';
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
--
--    The crawler runs every 10 minutes and writes a separate JSON file per
--    snapshot, but CWA reports observations on the wall-clock 10-minute
--    boundary. Two consecutive crawler files routinely contain the same
--    station_id × measure_at row, so the flattened source has duplicates
--    on the MERGE join key. BQ's MERGE refuses to apply a non-deterministic
--    UPDATE; we dedup with ROW_NUMBER, keeping the row with the latest
--    ingest_at (= the freshest crawler snapshot).
-- ----------------------------------------------------------------------------
EXECUTE IMMEDIATE FORMAT("""
  MERGE `%s.%s.observations` AS target
  USING (
    SELECT * EXCEPT(_dedup_rn) FROM (
      SELECT
        station.StationId    AS station_id,
        station.StationName  AS station_name,

        -- Measurement fields are STRING in the bronze observations target
        -- (per infra/bq/schemas/observations.json — preserves CWA sentinels
        -- 'X' / 'T' / '-99' / '-98' / '990'). The daily staging is loaded
        -- with autodetect, so its types depend on whichever values appeared
        -- that day. CAST AS STRING normalizes to match the target columns,
        -- so MERGE INSERT does not type-mismatch.
        CAST(station.WeatherElement.AirTemperature                      AS STRING) AS air_temperature,
        CAST(station.WeatherElement.AirPressure                         AS STRING) AS air_pressure,
        CAST(station.WeatherElement.RelativeHumidity                    AS STRING) AS relative_humidity,
        CAST(station.WeatherElement.WindSpeed                           AS STRING) AS wind_speed,
        CAST(station.WeatherElement.WindDirection                       AS STRING) AS wind_direction,
        CAST(station.WeatherElement.GustInfo.PeakGustSpeed              AS STRING) AS peak_gust_speed,
        CAST(station.WeatherElement.GustInfo.Occurred_at.WindDirection  AS STRING) AS wind_direction_gust,
        CAST(station.WeatherElement.Now.Precipitation                   AS STRING) AS precipitation,
        CAST(station.WeatherElement.SunshineDuration                    AS STRING) AS sunshine_duration_10min,
        CAST(station.WeatherElement.UVIndex                             AS STRING) AS uv_index,

        station.WeatherElement.Weather                             AS weather_status,
        station.WeatherElement.VisibilityDescription               AS visibility,

        station.GeoInfo.CountyName                                 AS county_name,
        CAST(station.GeoInfo.CountyCode                            AS STRING) AS county_code,
        station.GeoInfo.TownName                                   AS town_name,
        CAST(station.GeoInfo.TownCode                              AS STRING) AS town_code,
        station.GeoInfo.StationAltitude                            AS station_altitude,

        -- ObsTime.DateTime in source is ISO-8601 with offset; BQ autodetect
        -- promotes it to TIMESTAMP. Use directly.
        station.ObsTime.DateTime                                   AS measure_at,
        DATE(station.ObsTime.DateTime, 'Asia/Taipei')              AS measure_date,
        PARSE_TIMESTAMP('%%Y-%%m-%%d_%%H_%%M', ingested_at)        AS ingest_at,
        'new'                                                      AS ingest_source,

        CASE
          WHEN STARTS_WITH(station.StationId, '46') THEN '有人站'
          WHEN STARTS_WITH(station.StationId, 'C0')
            OR STARTS_WITH(station.StationId, 'C1') THEN '自動站'
          ELSE '農業雨量站'
        END AS station_type,

        ROW_NUMBER() OVER (
          PARTITION BY station.StationId, station.ObsTime.DateTime
          ORDER BY PARSE_TIMESTAMP('%%Y-%%m-%%d_%%H_%%M', ingested_at) DESC NULLS LAST
        ) AS _dedup_rn
      FROM `%s.%s.observations_daily_staging`,
      UNNEST(records.Station) AS station
    )
    WHERE _dedup_rn = 1
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
