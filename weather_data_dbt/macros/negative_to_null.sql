{%macro negative_to_null(column_name) %}
    (
        case 
            WHEN {{ column_name }} < 0 THEN null
            ELSE {{ column_name }}
        END
    )
{% endmacro %}