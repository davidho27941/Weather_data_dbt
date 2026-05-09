{# ----------------------------------------------------------------------------
   classify_station_type

   Returns the station classification ('有人站' / '自動站' / '農業雨量站') based
   on the prefix of a CWA station ID. The classification rule:

       prefix '46'           → 有人站 (manned weather station)
       prefix 'C0' or 'C1'   → 自動站 (automatic weather station)
       anything else         → 農業雨量站 (agricultural rain-fall station)

   This logic is also baked into the bronze CTAS in
   infra/bq/02_create_observations.sh, so observations data already arrives
   with `station_type` set. This macro exists for staging models that read
   from station-metadata bronze tables (which do not pre-compute the type).
---------------------------------------------------------------------------- #}
{% macro classify_station_type(station_id_column) %}
    case
        when starts_with({{ station_id_column }}, '46') then '有人站'
        when starts_with({{ station_id_column }}, 'C0')
          or starts_with({{ station_id_column }}, 'C1') then '自動站'
        else '農業雨量站'
    end
{% endmacro %}
