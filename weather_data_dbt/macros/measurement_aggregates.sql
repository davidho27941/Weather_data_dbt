{# ----------------------------------------------------------------------------
   measurement_aggregates

   Returns the SELECT clause fragment for time-grain rollup marts. Used by
   fct_measurements_hourly / daily / weekly / monthly so the per-grain
   query stays a one-liner difference (just the TIMESTAMP_TRUNC granularity).

   Aggregations chosen:
     - avg / max / min for instantaneous measurements (temperature, pressure,
       humidity, wind speed)
     - max for peak gust (already an extreme)
     - sum for cumulative quantities (precipitation, sunshine duration)
     - max for uv_index (peak UV during the bucket)
     - per-column observation counts so consumers can detect partial buckets

   Argument:
     table_alias  the table alias the columns come from (default 'm').

   Usage:
       SELECT
           station_id,
           timestamp_trunc(measure_at, hour) as measure_at,
           {{ measurement_aggregates('m') }}
       FROM {{ ref('int_measurements__cleaned') }} m
       GROUP BY 1, 2
---------------------------------------------------------------------------- #}
{% macro measurement_aggregates(table_alias='m') -%}
    -- temperature
    avg({{ table_alias }}.air_temperature)        as air_temperature_avg,
    max({{ table_alias }}.air_temperature)        as air_temperature_max,
    min({{ table_alias }}.air_temperature)        as air_temperature_min,
    countif({{ table_alias }}.air_temperature is not null) as air_temperature_obs_count,

    -- pressure (manned stations only)
    avg({{ table_alias }}.air_pressure)           as air_pressure_avg,
    max({{ table_alias }}.air_pressure)           as air_pressure_max,
    min({{ table_alias }}.air_pressure)           as air_pressure_min,
    countif({{ table_alias }}.air_pressure is not null) as air_pressure_obs_count,

    -- humidity
    avg({{ table_alias }}.relative_humidity)      as relative_humidity_avg,
    max({{ table_alias }}.relative_humidity)      as relative_humidity_max,
    min({{ table_alias }}.relative_humidity)      as relative_humidity_min,
    countif({{ table_alias }}.relative_humidity is not null) as relative_humidity_obs_count,

    -- wind
    avg({{ table_alias }}.wind_speed)             as wind_speed_avg,
    max({{ table_alias }}.wind_speed)             as wind_speed_max,
    max({{ table_alias }}.peak_gust_speed)        as peak_gust_speed_max,

    -- precipitation (cumulative within the bucket)
    sum({{ table_alias }}.precipitation)          as precipitation_sum,
    max({{ table_alias }}.precipitation)          as precipitation_max,
    countif({{ table_alias }}.precipitation is not null) as precipitation_obs_count,

    -- sunshine (sum of 10-minute durations gives the bucket total)
    sum({{ table_alias }}.sunshine_duration_10min) as sunshine_duration_sec,
    countif({{ table_alias }}.sunshine_duration_10min is not null) as sunshine_obs_count,

    -- uv (peak intensity during the bucket)
    max({{ table_alias }}.uv_index)               as uv_index_max,

    -- bucket coverage
    count(*)                                      as observation_count
{%- endmacro %}
