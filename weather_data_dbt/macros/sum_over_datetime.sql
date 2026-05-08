{% macro sum_over_datetime(column_name, timestamp_column_name, interval) %}

    ROUND(SUM( {{ column_name }} ) over (partition by station_id order by {{ timestamp_column_name }} range between interval '{{ interval }}' preceding and current row), 2)

{% endmacro %}