{{ config(severity='error') }}

{#
    Sentinel-translation invariant
    ------------------------------

    For every measurement field that goes through cwa_string_to_float in
    stg_observations, the cleaned column must be non-null whenever the
    raw column held a real value (i.e. raw is not null AND raw is not a
    documented sentinel for that field).

    A failure here means cwa_string_to_float silently dropped a value —
    either the regex/cast lost a legitimate reading, or a new
    undocumented CWA encoding showed up in the wild. Either way, it's a
    data-loss bug, not a "this is fine" case, so severity=error.

    Sentinel families (kept in lockstep with stg_observations.sql):

      Numeric default:
          'X' / '-99' / '-99.0' / '-999' / '-999.0'                  → NULL

      Wind direction (extra '990' / '990.0' = calm wind, no direction):
          numeric-default sentinels + '990' / '990.0'                → NULL

      Precipitation:
          'X' / '-99' / '-99.0' / '-999' / '-999.0' / '-990' / '-990.0'  → NULL
          'T' (trace) / '-98' (no rain past 6h)                      → 0   (NOT null)

    So for precipitation the "expected null" set excludes 'T' and '-98' —
    if raw='T' produces cleaned=NULL, that's still a bug because the
    contract says trace amounts become 0.
#}

{% set numeric_default_sentinels = "('X','-99','-99.0','-999','-999.0')" %}
{% set wind_direction_sentinels  = "('X','-99','-99.0','-999','-999.0','990','990.0')" %}
{% set precipitation_sentinels   = "('X','-99','-99.0','-999','-999.0','-990','-990.0')" %}

{# Per ADR-004 staging renames the cumulative columns for the two CWA
   fields that are actually daily-cumulative, so the invariant references
   their renamed staging names. The 10-min window derivations downstream
   of those columns are *not* checked here — this test is about the
   sentinel-translation contract (cleaned IS NULL whenever raw is a
   sentinel), not about the LAG-diff derivation. #}
{% set numeric_columns_default = [
    'air_temperature',
    'air_pressure',
    'relative_humidity',
    'wind_speed',
    'peak_gust_speed',
    'uv_index',
] %}
{% set wind_direction_columns = ['wind_direction', 'wind_direction_gust'] %}

with violations as (

    {%- for col in numeric_columns_default %}
    select
        '{{ col }}' as field_name,
        station_id,
        measure_at,
        {{ col }}_raw as raw_value
    from {{ ref('stg_observations') }}
    where {{ col }}_raw is not null
      and {{ col }}_raw not in {{ numeric_default_sentinels }}
      and {{ col }} is null
    union all
    {%- endfor %}

    {%- for col in wind_direction_columns %}
    select
        '{{ col }}' as field_name,
        station_id,
        measure_at,
        {{ col }}_raw as raw_value
    from {{ ref('stg_observations') }}
    where {{ col }}_raw is not null
      and {{ col }}_raw not in {{ wind_direction_sentinels }}
      and {{ col }} is null
    union all
    {%- endfor %}

    -- Daily-cumulative columns (renamed per ADR-004). Sentinels follow the
    -- numeric-default family; precipitation has its own extra rules below.
    select
        'sunshine_duration_daily_cumulative' as field_name,
        station_id,
        measure_at,
        sunshine_duration_daily_cumulative_raw as raw_value
    from {{ ref('stg_observations') }}
    where sunshine_duration_daily_cumulative_raw is not null
      and sunshine_duration_daily_cumulative_raw not in {{ numeric_default_sentinels }}
      and sunshine_duration_daily_cumulative is null
    union all

    select
        'precipitation_daily_cumulative' as field_name,
        station_id,
        measure_at,
        precipitation_daily_cumulative_raw as raw_value
    from {{ ref('stg_observations') }}
    where precipitation_daily_cumulative_raw is not null
      and precipitation_daily_cumulative_raw not in {{ precipitation_sentinels }}
      and precipitation_daily_cumulative is null
)

select * from violations
