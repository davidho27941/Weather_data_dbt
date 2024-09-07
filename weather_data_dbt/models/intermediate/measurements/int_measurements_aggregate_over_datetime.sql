{% set to_be_averaged = ['air_temperature', 'air_pressure', 'relative_humidity', 'wind_speed', 'precipitation'] %}
{% set to_be_summed = ['precipitation', 'sunshine_duration_10Min'] %}
{% set to_be_maxed = ['air_temperature', 'air_pressure', 'relative_humidity', 'wind_speed', 'peak_gust_speed',  'precipitation'] %}
-- {% set to_be_moded = ['wind_direction', 'wind_direction_gust'] %}

with measurements as (
    select * from {{ ref('stg_measurements__measurements') }}
), aggregated as (
    select

        -- existing columns
        *,

        -- hourly aggregated columns
        {% for columns in to_be_averaged %}

            {{ averaged_by_datetime( columns, 'measure_at', '1 hour' ) }} AS {{ columns }}_hourly_average,

        {% endfor %}

        {% for columns in to_be_summed %}

            {{ sum_over_datetime( columns, 'measure_at', '1 hour' ) }} AS {{ columns }}_hourly_sum,

        {% endfor %}

        {% for columns in to_be_maxed %}

            {{ find_max_in_interval( columns, 'measure_at', '1 hour' ) }} AS {{ columns }}_hourly_max,

        {% endfor %}


        -- daily aggregated columns
        {% for columns in to_be_averaged %}

            {{ averaged_by_datetime( columns, 'measure_at', '1 day' ) }} AS {{ columns }}_daily_average,

        {% endfor %}

        {% for columns in to_be_summed %}

            {{ sum_over_datetime( columns, 'measure_at', '1 day' ) }} AS {{ columns }}_daily_sum,

        {% endfor %}

        {% for columns in to_be_maxed %}

            {{ find_max_in_interval( columns, 'measure_at', '1 day' ) }} AS {{ columns }}_daily_max,

        {% endfor %}


        -- weekly aggregated columns
        {% for columns in to_be_averaged %}

            {{ averaged_by_datetime( columns, 'measure_at', '1 week' ) }} AS {{ columns }}_weekly_average,

        {% endfor %}

        {% for columns in to_be_summed %}

            {{ sum_over_datetime( columns, 'measure_at', '1 week' ) }} AS {{ columns }}_weekly_sum,

        {% endfor %}

        {% for columns in to_be_maxed %}

            {{ find_max_in_interval( columns, 'measure_at', '1 week' ) }} AS {{ columns }}_weekly_max,

        {% endfor %}

        -- monthly aggregated columns
        {% for columns in to_be_averaged %}

            {{ averaged_by_datetime( columns, 'measure_at', '1 month' ) }} AS {{ columns }}_monthly_average,

        {% endfor %}

        {% for columns in to_be_summed %}

            {{ sum_over_datetime( columns, 'measure_at', '1 month' ) }} AS {{ columns }}_monthly_sum,

        {% endfor %}

        {% for columns in to_be_maxed %}

            {{ find_max_in_interval( columns, 'measure_at', '1 month' ) }} AS {{ columns }}_monthly_max,

        {% endfor %}

    from measurements
)
{% if is_incremental() %}
, old_measurements as (
    select * from {{ this }}
)
{% endif %}


select * from aggregated
{% if is_incremental() %}

where measure_at > (
    select MAX(measure_at) from old_measurements
)

{% endif %}
