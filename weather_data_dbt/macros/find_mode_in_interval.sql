{% macro find_mode_in_interval(column_name, timestamp_column_name, interval) %}

    ROUND(MODE( {{ column_name }} ) over (partition by station_id order by {{ timestamp_column_name }} range between interval '{{ interval }}' preceding and current row), 2)

{% endmacro %}