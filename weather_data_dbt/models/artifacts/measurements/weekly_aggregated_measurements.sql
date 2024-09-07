{# 定義目標表格 #}
{% set table_name = ref('int_measurements_aggregate_over_datetime') %}

{# 獲取所有欄位 #}
{% set all_columns = adapter.get_columns_in_relation(table_name) %}


with measurements as (
    select * from {{ ref('int_measurements_aggregate_over_datetime') }}
), weekly_aggregated_data as (
    SELECT
        
        -- ids
        station_id,

        -- strings 
        station_name,
        station_type, 

        --timestamp
        measure_at,

        {% for col in all_columns %}

            {%- if col.name.endswith('WEEKLY_SUM') -%}

                {{ col.name }},
            
            {%- elif col.name.endswith('WEEKLY_AVERAGE') -%}

                {{ col.name }},

            {%- elif col.name.endswith('WEEKLY_MAX') -%}

                {{ col.name }},

            {%- endif -%}

        {% endfor %}

    from measurements
    WHERE measure_at = DATE_TRUNC('week', measure_at)
), renamed as (
    select 
        -- ids
        station_id,

        -- strings 
        station_name,
        station_type, 

        --timestamp
        measure_at,

        {% for col in all_columns %}

            {%- if col.name.endswith('WEEKLY_SUM') -%}

                {%- if col.name.startswith('SUNSHINE_DURATION_10MIN') -%}
                    
                    {{ col.name }} as {{ col.name | replace("_10MIN_WEEKLY_SUM", "") }},
                
                {% else %}
                    {{ col.name }} as {{ col.name | replace("_WEEKLY_SUM", "_SUM") }},
                
                {%- endif -%}
            
            {%- elif col.name.endswith('WEEKLY_AVERAGE') -%}

                {{ col.name }} as {{ col.name | replace("_WEEKLY_AVERAGE", "") }},

            {%- elif col.name.endswith('WEEKLY_MAX') -%}

                {{ col.name }} as {{ col.name | replace("_WEEKLY_MAX", "MAX") }} ,

            {%- endif -%}

        {% endfor %}

    FROM weekly_aggregated_data
)
{% if is_incremental() %}
, old_measurements as (
    select * from {{ this }}
)
{% endif %}

select * from renamed
{% if is_incremental() %}
where measure_at > (select MAX(measure_at) from old_measurements)
{% endif %}