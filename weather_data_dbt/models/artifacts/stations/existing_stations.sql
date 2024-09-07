with all_stations_information AS (
    select * from {{ ref('int_stations_joined_all_infomation') }}
)

select * from all_stations_information WHERE station_status = '現存測站'