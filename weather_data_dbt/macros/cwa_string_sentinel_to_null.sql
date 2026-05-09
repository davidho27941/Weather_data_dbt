{# CWA STRING-typed sentinel translation.

   For STRING fields like weather_status and visibility, CWA encodes:
     - '-99'  missing / abnormal data
     - 'X'    instrument malfunction

   Numeric fields use -99 / -999 sentinels and are handled by the
   companion macro cwa_sentinel_to_null.

   `extras` lets a caller add field-specific sentinel values (must be
   quoted strings).
#}
{% macro cwa_string_sentinel_to_null(column_name, extras=[]) %}
    (
        case
            when {{ column_name }} in ('-99', 'X'{% for v in extras %}, '{{ v }}'{% endfor %}) then null
            else {{ column_name }}
        end
    )
{% endmacro %}
