with all_stations_information AS (
    select * from {{ ref('int_stations_join_all_infomations') }}
)

select * from all_stations_information WHERE station_status = '現存測站'