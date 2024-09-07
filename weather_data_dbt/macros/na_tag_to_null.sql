{%macro na_tag_to_null(column_name) %}
    (
        case 
            WHEN {{ column_name }} = '-99' THEN null
            ELSE {{ column_name }}
        END
    )
{% endmacro %}