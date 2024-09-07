{% macro find_mode_in_interval(column_name, timestamp_column_name, interval) %}

    ROUND(MODE( {{ column_name }} ) over (order by {{ timestamp_column_name }} range between current row and interval '{{ interval }}' following), 2)

{% endmacro %}