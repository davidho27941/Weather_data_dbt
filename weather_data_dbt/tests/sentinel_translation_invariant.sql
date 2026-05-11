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

{% set numeric_columns = [
    'air_temperature',
    'air_pressure',
    'relative_humidity',
    'wind_speed',
    'peak_gust_speed',
    'sunshine_duration_10min',
    'uv_index',
] %}
{% set wind_direction_columns = ['wind_direction', 'wind_direction_gust'] %}

with violations as (

    {%- for col in numeric_columns %}
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

    select
        'precipitation' as field_name,
        station_id,
        measure_at,
        precipitation_raw as raw_value
    from {{ ref('stg_observations') }}
    where precipitation_raw is not null
      and precipitation_raw not in {{ precipitation_sentinels }}
      and precipitation is null
)

select * from violations
