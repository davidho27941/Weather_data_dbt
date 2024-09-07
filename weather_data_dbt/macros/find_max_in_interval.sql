{% macro find_max_in_interval(column_name, timestamp_column_name, interval) %}

    ROUND(MAX( {{ column_name }} ) over (partition by station_id order by {{ timestamp_column_name }} range between current row and interval '{{ interval }}' following), 2)

{% endmacro %}