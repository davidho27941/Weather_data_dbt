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

{# Strict 00:00 reset enforcement (per ADR-004 §X).

   Empirical observation (verified against GCS raw JSON, see ADR-004
   "Reconciliation evidence" and "GCS verification" sections):
   CWA O-A0003-001's `Now.Precipitation` and `Now.SunshineDuration`
   cumulatives do NOT reset exactly at Taipei 00:00. The 00:00 sample
   still carries the *previous* Taipei day's daily total verbatim; the
   reset happens between 00:00 and 00:10 (the 00:10 sample reads 0.0).
   For station 467571 (新竹) on Taipei 2026-04-27 the BQ trajectory is:
       23:50 of 04-26 → 13.0
       00:00 of 04-27 → 13.0   ← carryover, raw value
       00:10 of 04-27 → 0.0    ← reset done

   Our contract (this project's model) is: "Taipei 00:00 IS the daily
   reset boundary; the cumulative restarts at 0 there". To enforce that
   contract on the cleaned column we override the 00:00 sample's
   cleaned cumulative to 0.0 here. The `*_raw` column is NOT touched,
   so governance / audit can still recover CWA's literal value (13.0
   in the example above). This is the same dual-column principle as
   sentinel translation (per ADR-001 / ADR-002): bronze + *_raw stay
   faithful to CWA, *_cleaned reflects our consumption model.

   We deliberately accept that the daily cumulative ENDPOINT in our
   dataset can differ from CWA's web-portal hourly CSV (CODiS) by ~1-2
   hours/day for sunshine and ~1-2 mm/day for precipitation — that is
   a known CWA-internal inconsistency between the O-A0003-001 API
   (which we crawl) and CODiS post-processed hourly output (which we
   do not). Documented in ADR-004's "Known caveats" section.
#}
enforced_reset as (
    select * replace(
        case
            when extract(hour from measure_at at time zone 'Asia/Taipei') = 0
             and extract(minute from measure_at at time zone 'Asia/Taipei') = 0
             and precipitation is not null
            then 0.0
            else precipitation
        end as precipitation,
        case
            when extract(hour from measure_at at time zone 'Asia/Taipei') = 0
             and extract(minute from measure_at at time zone 'Asia/Taipei') = 0
             and sunshine_duration_10min is not null
            then 0.0
            else sunshine_duration_10min
        end as sunshine_duration_10min
    )
    from translated
),

{# Window-diff stage: turn the (now strict-00:00-reset-enforced)
   daily-cumulative columns into true 10-min window values.
     - Partition by Taipei date so the boundary aligns with the reset
       we just enforced.
     - Plain LAG (NOT IGNORE NULLS): a single sentinel observation
       blanks out the window value at that row AND the next row. This
       sacrifices the "preserve total across sentinel gaps" property
       for per-bucket correctness — bridging a gap would attribute
       multiple buckets' worth of increment to one bucket and produce
       physically-impossible window values.
     - Timestamp-gap guard: if measure_at jumps > 15 minutes between
       two rows (a real observation gap, not a sentinel), the window
       value is NULL — the difference is not a 10-min quantity.
     - First row of partition (Taipei 00:00): LAG returns NULL,
       window is NULL. Even though we overrode the cumulative to 0,
       we don't know what cum was at 23:59:59 of the previous Taipei
       day (it would have been the prev day's daily total, in a
       different partition). One observation per station per day
       forgone; 0.7% of the per-station daily samples.
     - Monotonicity violation (`current < previous` within partition):
       with strict 00:00 reset enforced, this should not occur on the
       00:10 boundary anymore. Mid-day violations would indicate a
       rare CWA correction; return NULL so accepted_range tests can
       surface the anomaly. #}
lagged as (
    select
        *,
        lag(precipitation) over (
            partition by station_id, date(measure_at, 'Asia/Taipei')
            order by measure_at
        ) as _prev_precip_cum,
        lag(sunshine_duration_10min) over (
            partition by station_id, date(measure_at, 'Asia/Taipei')
            order by measure_at
        ) as _prev_sunshine_cum,
        lag(measure_at) over (
            partition by station_id, date(measure_at, 'Asia/Taipei')
            order by measure_at
        ) as _prev_measure_at
    from enforced_reset
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
    -- amount, NULL when we cannot reliably attribute the increment to a
    -- single 10-min window (first row of Taipei day, sentinel on previous
    -- row, > 15 min gap between consecutive observations, or monotonicity
    -- violation). Rollup facts SUM this column.
    precipitation_raw as precipitation_daily_cumulative_raw,
    precipitation     as precipitation_daily_cumulative,
    case
        when precipitation is null then null
        when _prev_precip_cum is null then null
        when timestamp_diff(measure_at, _prev_measure_at, minute) > 15 then null
        when precipitation >= _prev_precip_cum then precipitation - _prev_precip_cum
        -- Monotonicity violation: a rare CWA mid-day correction. Don't
        -- fabricate negative rainfall; flag as NULL so accepted_range
        -- tests can surface the anomaly. With strict 00:00 reset
        -- enforcement (see enforced_reset CTE above), the reset boundary
        -- no longer triggers this branch in normal operation.
        else null
    end as precipitation_10min_window,

    -- ----- sunshine duration: same dual-column treatment -----------------
    sunshine_duration_10min_raw as sunshine_duration_daily_cumulative_raw,
    sunshine_duration_10min     as sunshine_duration_daily_cumulative,
    case
        when sunshine_duration_10min is null then null
        when _prev_sunshine_cum is null then null
        when timestamp_diff(measure_at, _prev_measure_at, minute) > 15 then null
        when sunshine_duration_10min >= _prev_sunshine_cum
            then sunshine_duration_10min - _prev_sunshine_cum
        -- Monotonicity violation: same rationale as precipitation above.
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
