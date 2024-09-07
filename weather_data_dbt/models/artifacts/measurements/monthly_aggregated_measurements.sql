{# 定義目標表格 #}
{% set table_name = ref('int_measurements_aggregate_over_datetime') %}

{# 獲取所有欄位 #}
{% set all_columns = adapter.get_columns_in_relation(table_name) %}


with measurements as (
    select * from {{ ref('int_measurements_aggregate_over_datetime') }}
), monthly_aggregated_data as (
    SELECT
        
        -- ids
        station_id,

        -- strings 
        station_name,
        station_type, 

        --timestamp
        measure_at,

        {% for col in all_columns %}

            {%- if col.name.endswith('MONTHLY_SUM') -%}

                {{ col.name }},
            
            {%- elif col.name.endswith('MONTHLY_AVERAGE') -%}

                {{ col.name }},

            {%- elif col.name.endswith('MONTHLY_MAX') -%}

                {{ col.name }},

            {%- endif -%}

        {% endfor %}

    from measurements
    WHERE measure_at = DATE_TRUNC('month', measure_at)
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

            {%- if col.name.endswith('MONTHLY_SUM') -%}

                {%- if col.name.startswith('SUNSHINE_DURATION_10MIN') -%}
                    
                    {{ col.name }} as {{ col.name | replace("_10MIN_MONTHLY_SUM", "") }},
                
                {% else %}
                    {{ col.name }} as {{ col.name | replace("_MONTHLY_SUM", "_SUM") }},
                
                {%- endif -%}
            
            {%- elif col.name.endswith('MONTHLY_AVERAGE') -%}

                {{ col.name }} as {{ col.name | replace("_MONTHLY_AVERAGE", "") }},

            {%- elif col.name.endswith('MONTHLY_MAX') -%}

                {{ col.name }} as {{ col.name | replace("_MONTHLY_MAX", "MAX") }} ,

            {%- endif -%}

        {% endfor %}

    FROM monthly_aggregated_data
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