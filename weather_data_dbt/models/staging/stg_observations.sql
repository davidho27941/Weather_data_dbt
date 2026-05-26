{{ config(materialized='view') }}

{#
    stg_observations
    ----------------

    Bronze observations are flat (one row per (station_id, measure_at)) with
    measurement fields stored as STRING — preserving CWA's raw sentinel
    encoding ('X', 'T', '-99', '-98', '990'). Staging produces TWO columns
    per measurement:

        <field>_raw    STRING   the original CWA value (auditable, unchanged)
        <field>        FLOAT64  cleaned: sentinels translated, real values cast

    This dual-column pattern lets downstream choose:
      - ML pipelines: use the cleaned column.
      - Data-quality / governance / debugging: use the raw column.
      - "Was this 0 because of trace rain, or because there was no rain in
        6 hours?" — answerable from the raw column.

    Sentinel translation rules (per CWA O-A0003-001 spec V1.05):

        Default numeric:
            'X' / -99 / -999            → NULL

        Wind direction (extra 990):
            'X' / -99 / -999 / 990      → NULL  (990 = calm wind, undefined dir)

        Precipitation (T and -98 mean "no rain"):
            'X' / -99 / -999            → NULL
            'T'                         → 0   (trace amount, semantically no rain)
            -98                         → 0   (no rain in past 6 hours)
            -990                        → NULL (undocumented legacy sentinel)

        Strings (weather_status, visibility):
            '-99' / 'X'                 → NULL
            (Note: 'X' not in spec for these two but kept defensively)

    Numeric sentinels are matched via SAFE_CAST(...) so '-99' and '-99.0'
    (legacy decimal form) are caught equivalently.

    Capability flags
    ----------------
    PR #2's verify.sh found ~90% sentinel values for air_pressure /
    sunshine_duration / uv_index. Those are NOT missing data — automatic
    stations (C0/C1 prefix) don't carry those sensors at all. The
    `has_*_sensor` columns let downstream distinguish "field not measured
    at this station" from "measurement missing at this snapshot".

    Daily-cumulative semantics (precipitation / sunshine_duration)
    --------------------------------------------------------------
    Per ADR-004: O-A0003-001's `WeatherElement.Now.Precipitation` and
    `WeatherElement.Now.SunshineDuration` are **daily-cumulative since
    Asia/Taipei midnight**, not 10-min windows. Bronze stores them
    verbatim (still named `precipitation` / `sunshine_duration_10min`
    there, per ADR-001); staging exposes them as
    `*_daily_cumulative` AND derives a true 10-min window column via
    LAG-diff partitioned by (station_id, Asia/Taipei date):

        precipitation_daily_cumulative_raw      / precipitation_daily_cumulative
        precipitation_10min_window              (derived)
        sunshine_duration_daily_cumulative_raw  / sunshine_duration_daily_cumulative
        sunshine_duration_10min_window          (derived)

    Derivation rules:
      - First obs of each Taipei day (no LAG row) → derived = current
        cumulative (the snapshot itself is the day's first 10-min total).
      - LAG(... IGNORE NULLS) so sentinel→NULL gaps don't blow up the
        differencing; a missed observation attributes its increment to
        the next valid bucket rather than to NULL.
      - Monotonicity violation (current < previous within the same Taipei
        day, e.g. CWA mid-day correction) → derived = NULL. Don't
        fabricate negative rainfall.
#}

{# Numeric measurement fields where only -99/-999/X are sentinels. #}
{%- set numeric_columns = [
    'air_temperature',
    'air_pressure',
    'relative_humidity',
    'wind_speed',
    'peak_gust_speed',
    'sunshine_duration_10min',
    'uv_index',
] -%}

{# Wind direction columns get an extra 990 sentinel ("calm wind"). #}
{%- set wind_direction_columns = [
    'wind_direction',
    'wind_direction_gust',
] -%}

with bronze as (
    select * from {{ source('weather_raw', 'observations') }}
    {%- if var('ci_sample_days', 0) | int > 0 %}
    -- CI subsample: keep build under a minute on the most recent N days of bronze.
    -- Set via --vars '{ci_sample_days: 7}' from the GHA workflow; default 0 = full.
    where measure_at >= timestamp_sub(current_timestamp(), interval {{ var('ci_sample_days') | int }} day)
    {%- endif %}
),

translated as (
    select
        -- ids and station context
        station_id,
        station_name,
        station_type,

        -- station capability flags (from station_type, not from data values).
        -- Only manned stations (有人站) carry the full sensor suite.
        station_type = '有人站' as has_pressure_sensor,
        station_type = '有人站' as has_sunshine_sensor,
        station_type = '有人站' as has_uv_sensor,

        -- ----- numeric measurements: raw + cleaned ---------------------------
        {% for col in numeric_columns -%}
        {{ col }} as {{ col }}_raw,
        {{ cwa_string_to_float(col) }} as {{ col }},
        {% endfor %}

        -- ----- wind direction: raw + cleaned (extra 990 sentinel) ------------
        {% for col in wind_direction_columns -%}
        {{ col }} as {{ col }}_raw,
        {{ cwa_string_to_float(col, extra_null_numeric=[990]) }} as {{ col }},
        {% endfor %}

        -- ----- precipitation: raw + cleaned ('T' / -98 → 0; rest → NULL) -----
        -- Legacy data carries an undocumented -990 sentinel; treat it as NULL.
        precipitation as precipitation_raw,
        {{ cwa_string_to_float(
            'precipitation',
            zero_strings=['T'],
            zero_numerics=[-98],
            extra_null_numeric=[-990]
        ) }} as precipitation,

        -- ----- string measurements: raw + cleaned ----------------------------
        weather_status as weather_status_raw,
        {{ cwa_string_sentinel_to_null('weather_status') }} as weather_status,
        visibility as visibility_raw,
        {{ cwa_string_sentinel_to_null('visibility') }} as visibility,

        -- ----- geo + time + provenance ---------------------------------------
        county_name,
        county_code,
        town_name,
        town_code,
        station_altitude,

        measure_at,
        measure_date,
        ingest_at,
        ingest_source
    from bronze
),

{# Window-diff stage: turn the daily-cumulative `precipitation` /
   `sunshine_duration_10min` columns into true 10-min window values.
   See ADR-004 for the full rationale; the key points are:
     - Partition by Taipei date so the reset boundary matches CWA's spec.
     - IGNORE NULLS so sentinel→NULL gaps don't break differencing.
     - Monotonicity-violation guard returns NULL, not a negative value. #}
lagged as (
    select
        *,
        lag(precipitation ignore nulls) over (
            partition by station_id, date(measure_at, 'Asia/Taipei')
            order by measure_at
        ) as _prev_precip_cum,
        lag(sunshine_duration_10min ignore nulls) over (
            partition by station_id, date(measure_at, 'Asia/Taipei')
            order by measure_at
        ) as _prev_sunshine_cum
    from translated
)

select
    -- ids and station context
    station_id,
    station_name,
    station_type,

    -- capability flags
    has_pressure_sensor,
    has_sunshine_sensor,
    has_uv_sensor,

    -- ----- numeric measurements unchanged --------------------------------
    air_temperature_raw,
    air_temperature,
    air_pressure_raw,
    air_pressure,
    relative_humidity_raw,
    relative_humidity,
    wind_speed_raw,
    wind_speed,
    peak_gust_speed_raw,
    peak_gust_speed,
    uv_index_raw,
    uv_index,

    -- ----- wind direction unchanged --------------------------------------
    wind_direction_raw,
    wind_direction,
    wind_direction_gust_raw,
    wind_direction_gust,

    -- ----- precipitation: cumulative + derived 10-min window -------------
    -- `precipitation_daily_cumulative` is the raw-ish CWA value (sentinels
    -- already translated by cwa_string_to_float). Per ADR-004 it is the
    -- running total since Asia/Taipei midnight, NOT the past 10 minutes.
    -- `precipitation_10min_window` is the LAG-diff derived true 10-min
    -- amount; this is what downstream rollups SUM.
    precipitation_raw as precipitation_daily_cumulative_raw,
    precipitation     as precipitation_daily_cumulative,
    case
        when precipitation is null then null
        when _prev_precip_cum is null then precipitation
        when precipitation >= _prev_precip_cum then precipitation - _prev_precip_cum
        else null
    end as precipitation_10min_window,

    -- ----- sunshine duration: same dual-column treatment -----------------
    sunshine_duration_10min_raw as sunshine_duration_daily_cumulative_raw,
    sunshine_duration_10min     as sunshine_duration_daily_cumulative,
    case
        when sunshine_duration_10min is null then null
        when _prev_sunshine_cum is null then sunshine_duration_10min
        when sunshine_duration_10min >= _prev_sunshine_cum
            then sunshine_duration_10min - _prev_sunshine_cum
        else null
    end as sunshine_duration_10min_window,

    -- ----- strings, geo, time, provenance --------------------------------
    weather_status_raw,
    weather_status,
    visibility_raw,
    visibility,

    county_name,
    county_code,
    town_name,
    town_code,
    station_altitude,

    measure_at,
    measure_date,
    ingest_at,
    ingest_source
from lagged
