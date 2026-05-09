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
)

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
