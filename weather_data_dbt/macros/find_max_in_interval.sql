{% macro find_max_in_interval(column_name, timestamp_column_name, interval) %}

    ROUND(MAX( {{ column_name }} ) over (partition by station_id order by {{ timestamp_column_name }} range between interval '{{ interval }}' preceding and current row), 2)

{% endmacro %}