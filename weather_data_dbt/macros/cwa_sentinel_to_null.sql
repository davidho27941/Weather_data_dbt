{# CWA / 農業 API 對缺值的慣例為 -99 或 -999。
   原 negative_to_null 用 (< 0) 判斷會把合法的零下氣溫誤判為缺值。 #}
{% macro cwa_sentinel_to_null(column_name) %}
    (
        case
            when {{ column_name }} in (-99, -999) then null
            else {{ column_name }}
        end
    )
{% endmacro %}
