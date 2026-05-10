# Weather Data dbt — 架構重構設計提案

> 目標：將現有 Snowflake-based 專案搬遷到 BigQuery，並依據 dbt best practice 重構 staging / intermediate / mart 三層，讓最終 artifact 是給資料科學家可以直接 `SELECT` 用的 ML 訓練輔助資料。
>
> 本文件僅為設計提案。執行前請先 review 並就疑問處回饋。

---

## 0. TL;DR — 主要變更

| 面向 | 現況 | 提案 |
|---|---|---|
| Warehouse | Snowflake external table + JSON | BigQuery external table（GCS）+ `JSON_VALUE` |
| 時間粒度產出 | 在 int 用 row-level rolling window，mart 用 `DATE_TRUNC` 過濾整點列 | int 做清洗，mart 用 `GROUP BY TIMESTAMP_TRUNC` 真實 rollup |
| 寬度 | 1 張超寬 int（4 grain × 3 agg × N col） | 4 張 mart，每張 grain 獨立 |
| Incremental | `WHERE measure_at > MAX(measure_at)`，無 unique_key | `merge` + `unique_key=['station_id', 'measure_at']` + lookback window |
| 命名 | `artifacts/`、`int_..._infomations`（typo） | `marts/`、`fct_*` / `dim_*` |
| Bug | 氣溫負值被當缺值 / `country_*` 應為 `county_*` / window 方向錯 | 全部修正（見 §1） |
| Test / yml | 大量 `...TBD`、無 generic test | 每張 mart 補 unique / not_null / relationships |

---

## 1. 必須修正的 bug

### 1.1 `negative_to_null` 不應套用在 `air_temperature`
零下氣溫合法。CWA API 缺值是 `-99` 或 `-999`，應改用 sentinel 比對而非「< 0」。

```sql
-- 新 macro: cwa_sentinel_to_null
{% macro cwa_sentinel_to_null(column_name) %}
    case
        when {{ column_name }} in (-99, -999) then null
        else {{ column_name }}
    end
{% endmacro %}
```

各欄位的合法範圍另外用 dbt test（`dbt_utils.expression_is_true` 或 `accepted_range`）驗證，例如氣溫 `[-30, 50]`、相對濕度 `[0, 100]`。

### 1.2 Rolling window 方向錯誤
現行 `range between current row and interval '1 hour' following`（向後看）。**做 ML feature 時這是 target leakage**——訓練時模型會看到「未來」。

由於本次選定 GROUP BY rollup 模式，row-level rolling 不在 mart 必要範圍。如未來要做 rolling feature，正確語法應為：

```sql
-- BigQuery 語法（rolling window 需要 numeric/timestamp range）
range between 3600 preceding and current row  -- 過去 1 小時
-- 或用 ROWS（要先確認資料採樣間距均勻）
```

### 1.3 Mart rename 產生畸形欄名
`{{ col.name | replace("_HOURLY_MAX", "MAX") }}` → `AIR_TEMPERATUREMAX`（缺底線）。
本次改為 GROUP BY rollup，欄名直接在 SELECT 中明確列出，不再依賴字串替換。

### 1.4 `country_*` ↔ `county_*` 拼字
CWA `CountyName / CountyCode` 是「縣市」（county）。三個 model 全改：
- `stg_measurements__station_geo` → `county_name`、`county_code`
- `stg_weather_stn__stations` → `county_name`
- `int_stations__unioned`、`dim_stations` → `county_name`、`county_code`

### 1.5 Incremental 缺 `unique_key`
所有 incremental model 加上 `unique_key=['station_id', 'measure_at']`，搭配 `incremental_strategy='merge'`。

### 1.6 其他小修
- `dbt_project.yml` 的 `name: 'my_new_project'` → `name: 'weather_data_dbt'`
- CTE typo `ranamed` → `renamed`
- File typo `int_stations_join_all_infomations` → `int_stations__unioned`
- `_int_measurements__models.yml` 的三個不存在 model 條目刪掉

---

## 2. 目標 DAG

```
sources
├── ext_measurements          (GCS → BQ external table，10 分鐘 CWA 觀測 JSON)
├── ext_weather_stations      (CWA 測站 metadata JSON)
└── ext_rain_fall_stations    (農業雨量站 metadata JSON)

staging  (view，純 rename + 型別轉換 + JSON flatten)
├── stg_measurements__raw_records.sql      ← flatten JSON 一次
├── stg_measurements__observations.sql     ← 從 raw_records 派生觀測值
├── stg_measurements__station_geo.sql      ← 從 raw_records 派生 TW97 座標
├── stg_weather_stn__stations.sql
└── stg_rain_fall_stn__stations.sql

intermediate  (table or ephemeral，business logic)
├── int_measurements__cleaned.sql          ← sentinel→null、dedup、station_type 標註
└── int_stations__unioned.sql              ← 三個 station 來源 union/合併

marts
├── dim_stations.sql                       ← 一張 station 維度（含 status、座標、類型）
├── fct_measurements_10min.sql             ← 原始粒度（清洗後）+ station context
├── fct_measurements_hourly.sql            ← GROUP BY TIMESTAMP_TRUNC(measure_at, HOUR)
├── fct_measurements_daily.sql
├── fct_measurements_weekly.sql            ← TIMESTAMP_TRUNC(measure_at, WEEK)
└── fct_measurements_monthly.sql

(輔助)
├── stations_existing.sql      ← 直接 view: dim_stations WHERE status = '現存測站'
└── stations_revoked.sql       ← 直接 view: dim_stations WHERE status = '已撤銷'
```

DAG 節點數從現在 11 增加到 13，但每張表職責清楚，下游 ML 使用者只要選對應 grain 的 `fct_measurements_*` 即可，不用再 join。

---

## 3. `dbt_project.yml` 變更

```yaml
name: 'weather_data_dbt'
version: '1.0.0'
config-version: 2
profile: 'weather_data_dbt'

require-dbt-version: ">=1.8.0"

model-paths: ["models"]
macro-paths: ["macros"]
test-paths:  ["tests"]
seed-paths:  ["seeds"]
snapshot-paths: ["snapshots"]
analysis-paths: ["analyses"]

vars:
  # 遲到資料 lookback：每次 incremental 重算過去 N 天
  measurements_lookback_days: 3

models:
  weather_data_dbt:
    +persist_docs:
      relation: true
      columns: true

    staging:
      +schema: staging
      +materialized: view

    intermediate:
      +schema: intermediate
      +materialized: table   # 規模還小，table 即可

    marts:
      +schema: marts
      +materialized: incremental
      +incremental_strategy: merge
      +on_schema_change: append_new_columns
      # BigQuery 特有：partition + cluster 提升查詢效率
      +partition_by:
        field: measure_at
        data_type: timestamp
        granularity: day
      +cluster_by: ['station_id']

      dim_stations:
        +materialized: table   # 維度表全量重建
```

關鍵點：
- BigQuery 上 `incremental_strategy='merge'` 是預設且最安全。
- `partition_by` + `cluster_by` 是 BigQuery 的核心成本控制機制——大表必設。
- `on_schema_change: append_new_columns` 讓你新增欄位時不用 `--full-refresh`。

---

## 4. Staging Layer（BigQuery 語法草稿）

> **⚠️ 補充於 §12**：本章節原本的 source 名稱（`source('measurements', 'ext_measurements')`）為示意；實際應改為 §12 所定義的 `source('weather_raw', 'ext_weather_observations')` 等。下方 SQL 結構仍適用，僅 source 引用需替換。

### 4.1 `stg_measurements__raw_records.sql`

> **新增**：把 JSON flatten 抽出來，下游 observations / station_geo 共用，避免重複 parse。

```sql
{{ config(materialized='view') }}

with source as (
    select * from {{ source('measurements', 'ext_measurements') }}
),

flattened as (
    -- BigQuery: external table 的 JSON 通常以 STRING 或 JSON 型別存放
    -- 以下假設 source 表有一欄 `value` 是 JSON 型別 (BigQuery JSON type)
    select
        record
    from source,
        unnest(json_query_array(value, '$.records')) as record
)

select * from flattened
```

> 註：實際 JSON path 視 GCS load 後的 schema 而定。若整份 JSON 用 STRING 欄位儲存，`json_query_array` 改 `JSON_EXTRACT_ARRAY` 並把後續 `JSON_VALUE` 對應改寫即可。

### 4.2 `stg_measurements__observations.sql`

```sql
{{ config(materialized='view') }}

{%- set numeric_columns = [
    'air_temperature', 'air_pressure', 'relative_humidity',
    'wind_speed', 'wind_direction', 'wind_direction_gust',
    'peak_gust_speed', 'precipitation', 'sunshine_duration_10min',
    'uv_index'
] -%}
{%- set string_columns = ['visibility', 'weather_status'] -%}

with raw as (
    select * from {{ ref('stg_measurements__raw_records') }}
),

renamed as (
    select
        json_value(record, '$.StationId')                                           as station_id,
        json_value(record, '$.StationName')                                         as station_name,

        cast(json_value(record, '$.WeatherElement.AirTemperature')      as float64) as air_temperature,
        cast(json_value(record, '$.WeatherElement.AirPressure')         as float64) as air_pressure,
        cast(json_value(record, '$.WeatherElement.RelativeHumidity')    as float64) as relative_humidity,
        cast(json_value(record, '$.WeatherElement.WindSpeed')           as float64) as wind_speed,
        cast(json_value(record, '$.WeatherElement.WindDirection')       as float64) as wind_direction,
        cast(json_value(record, '$.WeatherElement.GustInfo.Occurred_at.WindDirection') as float64) as wind_direction_gust,
        cast(json_value(record, '$.WeatherElement.GustInfo.PeakGustSpeed') as float64) as peak_gust_speed,
        cast(json_value(record, '$.WeatherElement.Now.Precipitation')   as float64) as precipitation,
        cast(json_value(record, '$.WeatherElement.SunshineDuration')    as float64) as sunshine_duration_10min,
        cast(json_value(record, '$.WeatherElement.UVIndex')             as float64) as uv_index,

        json_value(record, '$.WeatherElement.Weather')                              as weather_status,
        json_value(record, '$.WeatherElement.VisibilityDescription')                as visibility,

        timestamp(json_value(record, '$.ObsTime.DateTime'))                         as measure_at

    from raw
)

select * from renamed
```

設計重點：
- staging **只做 rename + 型別**，不做 sentinel 處理、不做 dedup、不做業務邏輯。
- `station_type` 分類在 intermediate 處理（單一處事實），不再三處複製。

### 4.3 `stg_measurements__station_geo.sql`

```sql
{{ config(materialized='view') }}

with raw as (
    select * from {{ ref('stg_measurements__raw_records') }}
)

select distinct
    json_value(record, '$.StationId')                                                 as station_id,
    json_value(record, '$.GeoInfo.CountyName')                                        as county_name,
    json_value(record, '$.GeoInfo.CountyCode')                                        as county_code,
    json_value(record, '$.GeoInfo.TownName')                                          as town_name,
    json_value(record, '$.GeoInfo.TownCode')                                          as town_code,
    json_value(record, '$.GeoInfo.Coordinates[0].CoordinateFormat')                   as coordinate_format,
    cast(json_value(record, '$.GeoInfo.Coordinates[0].StationLatitude')  as float64)  as station_latitude_tw97,
    cast(json_value(record, '$.GeoInfo.Coordinates[0].StationLongitude') as float64)  as station_longitude_tw97,
    cast(json_value(record, '$.GeoInfo.StationAltitude')                 as float64)  as station_altitude
from raw
```

### 4.4 `stg_weather_stn__stations.sql` & `stg_rain_fall_stn__stations.sql`

語法上做兩件事：
1. Snowflake 的 `lateral flatten` → BigQuery `unnest` + `json_query_array`。
2. 空字串 → null 用 `nullif(...,'')` 取代 CASE WHEN。

範例片段：
```sql
nullif(json_value(record, '$.OriginalStationID'), '')                  as original_station_id,
safe_cast(nullif(json_value(record, '$.StationStartDate'), '') as date) as start_at
```

---

## 5. Intermediate Layer

### 5.1 `int_measurements__cleaned.sql`

職責：sentinel → null、dedup、附加 `station_type`。**不做時間聚合。**

```sql
{{
    config(
        materialized='incremental',
        incremental_strategy='merge',
        unique_key=['station_id', 'measure_at'],
        partition_by={'field': 'measure_at', 'data_type': 'timestamp', 'granularity': 'day'},
        cluster_by=['station_id'],
    )
}}

with observations as (
    select * from {{ ref('stg_measurements__observations') }}
    {% if is_incremental() %}
      where measure_at >= timestamp_sub(
          (select max(measure_at) from {{ this }}),
          interval {{ var('measurements_lookback_days') }} day
      )
    {% endif %}
),

cleaned as (
    select
        station_id,
        station_name,
        {{ classify_station_type('station_id') }} as station_type,

        {{ cwa_sentinel_to_null('air_temperature') }}        as air_temperature,
        {{ cwa_sentinel_to_null('air_pressure') }}           as air_pressure,
        {{ cwa_sentinel_to_null('relative_humidity') }}      as relative_humidity,
        {{ cwa_sentinel_to_null('wind_speed') }}             as wind_speed,
        {{ cwa_sentinel_to_null('wind_direction') }}         as wind_direction,
        {{ cwa_sentinel_to_null('wind_direction_gust') }}    as wind_direction_gust,
        {{ cwa_sentinel_to_null('peak_gust_speed') }}        as peak_gust_speed,
        {{ cwa_sentinel_to_null('precipitation') }}          as precipitation,
        {{ cwa_sentinel_to_null('sunshine_duration_10min') }} as sunshine_duration_10min,
        {{ cwa_sentinel_to_null('uv_index') }}               as uv_index,

        nullif(weather_status, '-99') as weather_status,
        nullif(visibility, '-99')     as visibility,

        measure_at
    from observations
),

deduped as (
    select * except(rn)
    from (
        select
            *,
            row_number() over (
                partition by station_id, measure_at
                order by measure_at  -- TODO: 若 raw 有 ingest_at，加為 tiebreaker
            ) as rn
        from cleaned
    )
    where rn = 1
)

select * from deduped
```

### 5.2 `int_stations__unioned.sql`

把現行 `int_stations_join_all_infomations` 重新組織為一張乾淨的 station 維度——但**先不做最終 dim**，留給 mart 層加上欄位敘述。

關鍵改動：
- `country_*` → `county_*`
- `station_type` 用統一 macro `classify_station_type`
- 改用 `coalesce` + `full outer join` 串接三個來源（與現行邏輯相同，但欄名與 macro 統一）

---

## 6. Mart Layer

### 6.1 共用 macro：`measurement_aggregates`

避免 4 張 grain mart 重複貼相同 `avg / sum / max` 區塊。

```sql
{% macro measurement_aggregates(table_alias='m') %}
    avg({{ table_alias }}.air_temperature)        as air_temperature_avg,
    max({{ table_alias }}.air_temperature)        as air_temperature_max,
    min({{ table_alias }}.air_temperature)        as air_temperature_min,

    avg({{ table_alias }}.air_pressure)           as air_pressure_avg,
    max({{ table_alias }}.air_pressure)           as air_pressure_max,

    avg({{ table_alias }}.relative_humidity)      as relative_humidity_avg,

    avg({{ table_alias }}.wind_speed)             as wind_speed_avg,
    max({{ table_alias }}.wind_speed)             as wind_speed_max,
    max({{ table_alias }}.peak_gust_speed)        as peak_gust_speed_max,

    sum({{ table_alias }}.precipitation)          as precipitation_sum,
    max({{ table_alias }}.precipitation)          as precipitation_max,

    sum({{ table_alias }}.sunshine_duration_10min) as sunshine_duration_sec,
    max({{ table_alias }}.uv_index)               as uv_index_max,

    count(*)                                      as observation_count,
    countif({{ table_alias }}.air_temperature is not null) as air_temperature_obs_count
{% endmacro %}
```

### 6.2 `fct_measurements_hourly.sql`

```sql
{{
    config(
        materialized='incremental',
        incremental_strategy='merge',
        unique_key=['station_id', 'measure_at'],
        partition_by={'field': 'measure_at', 'data_type': 'timestamp', 'granularity': 'day'},
        cluster_by=['station_id'],
    )
}}

with measurements as (
    select * from {{ ref('int_measurements__cleaned') }}
    {% if is_incremental() %}
      where measure_at >= timestamp_sub(
          (select max(measure_at) from {{ this }}),
          interval {{ var('measurements_lookback_days') }} day
      )
    {% endif %}
),

stations as (
    select * from {{ ref('dim_stations') }}
),

bucketed as (
    select
        station_id,
        timestamp_trunc(measure_at, hour) as measure_at,
        {{ measurement_aggregates('measurements') }}
    from measurements
    group by station_id, timestamp_trunc(measure_at, hour)
)

select
    b.station_id,
    b.measure_at,

    -- station context (給 ML 直接用，不用再 join)
    s.station_name,
    s.station_type,
    s.county_name,
    s.town_name,
    s.station_latitude_wgs84,
    s.station_longitude_wgs84,
    s.station_altitude,

    -- aggregates
    b.air_temperature_avg, b.air_temperature_max, b.air_temperature_min,
    b.air_pressure_avg, b.air_pressure_max,
    b.relative_humidity_avg,
    b.wind_speed_avg, b.wind_speed_max, b.peak_gust_speed_max,
    b.precipitation_sum, b.precipitation_max,
    b.sunshine_duration_sec,
    b.uv_index_max,
    b.observation_count,
    b.air_temperature_obs_count
from bucketed b
left join stations s using (station_id)
```

### 6.3 `fct_measurements_daily / weekly / monthly`

幾乎一致，僅 `timestamp_trunc(measure_at, DAY|WEEK|MONTH)` 不同。可以再進一步抽 macro `bucketed_measurements(grain='hour')`，但個人建議**先寫四份明確 SQL**，避免過度抽象——四份只差一個關鍵字，未來新增 grain 也很直觀。

### 6.4 `fct_measurements_10min`

原始粒度也輸出一份（直接 `select * from int_measurements__cleaned LEFT JOIN dim_stations`），給需要原始解析度的使用者。

### 6.5 `dim_stations.sql`

```sql
{{ config(materialized='table') }}

with unioned as (select * from {{ ref('int_stations__unioned') }})

select
    station_id,
    original_station_id,
    new_station_id,
    station_name,
    station_name_en,
    {{ classify_station_type('station_id') }} as station_type,
    station_status,                      -- 現存 / 已撤銷
    county_code, county_name,
    town_code, town_name,
    location, notes,
    station_altitude,
    station_longitude as station_longitude_wgs84,
    station_latitude  as station_latitude_wgs84,
    station_longitude_tw97,
    station_latitude_tw97,
    start_at, end_at
from unioned
```

`stations_existing.sql` / `stations_revoked.sql` 變成 view：

```sql
{{ config(materialized='view') }}
select * from {{ ref('dim_stations') }} where station_status = '現存測站'
```

---

## 7. Macros 重整

| Macro | 用途 | 變動 |
|---|---|---|
| `cwa_sentinel_to_null` | 把 -99/-999 轉 null | **新增**，取代 `negative_to_null` 與 `na_tag_to_null` 兩者 |
| `classify_station_type` | 根據 station_id 前綴推斷站別 | **新增**（macro 化原本散落三處的 CASE） |
| `measurement_aggregates` | 共用 grain rollup 欄位清單 | **新增** |
| `averaged_by_datetime` / `sum_over_datetime` / `find_max_in_interval` / `find_mode_in_interval` | 原 row-level rolling window | **刪除**（GROUP BY 模式不需要）。若未來要做 ML rolling feature 再加回，且記得是 `preceding`。 |
| `negative_to_null` | 既錯誤套用又語意不對 | **刪除** |
| `na_tag_to_null` | 只處理單一 sentinel | **刪除**（被 cwa_sentinel_to_null 取代） |

`classify_station_type` 範例：
```sql
{% macro classify_station_type(station_id_column) %}
    case
        when starts_with({{ station_id_column }}, '46')                          then '有人站'
        when starts_with({{ station_id_column }}, 'C0')
          or starts_with({{ station_id_column }}, 'C1')                          then '自動站'
        else '農業雨量站'
    end
{% endmacro %}
```

---

## 8. Tests & YAML schema

每個 mart 都要有最小 test 集合：

```yaml
version: 2

models:
  - name: fct_measurements_hourly
    description: |
      Hourly aggregated weather observations per station.
      Granularity: one row per (station_id, hour bucket).
    columns:
      - name: station_id
        description: CWA station id
        tests: [not_null]
      - name: measure_at
        description: Timestamp truncated to the hour (UTC).
        tests: [not_null]
      - name: air_temperature_avg
        tests:
          - dbt_utils.accepted_range:
              min_value: -30
              max_value: 50
              inclusive: true
      - name: relative_humidity_avg
        tests:
          - dbt_utils.accepted_range:
              min_value: 0
              max_value: 100
    tests:
      - dbt_utils.unique_combination_of_columns:
          combination_of_columns: [station_id, measure_at]
      - relationships:
          to: ref('dim_stations')
          field: station_id
          column_name: station_id
```

至少要加：
- `dim_stations.station_id`：`unique`、`not_null`
- 每個 `fct_*`：(station_id, measure_at) 組合 `unique`
- 數值欄位：`accepted_range`（這也是把 sentinel bug 早期攔下的安全網）
- Source freshness：對 `ext_measurements` 設 `loaded_at_field` 與 `freshness` 警示

---

## 9. BigQuery 特有最佳實務

| 主題 | 建議 |
|---|---|
| Partition | 所有時序 mart 都 `partition_by` `measure_at` (DAY)。減少 incremental MERGE 掃描成本。 |
| Cluster | `cluster_by=['station_id']`。最常見過濾條件。 |
| `incremental_predicates` | 在 MERGE 時加上 `DBT_INTERNAL_DEST.measure_at >= timestamp_sub(current_timestamp(), interval 7 day)`，避免 MERGE 掃描整張歷史表。 |
| External table | GCS JSON 用 `EXTERNAL` 表 + `hive_partition` 載入；source 設 `loaded_at_field` 用 `_FILE_MODIFICATION_TIME` 做 freshness check。 |
| `safe_cast` | JSON value 強型轉一律用 `safe_cast` 避免單筆爛資料炸整個 run。 |
| Slot 控制 | 開發期 `--limit` + dev dataset；正式跑加 `query_label` 標記成本。 |

---

## 10. 遷移步驟（建議順序）

> 每一步建議獨立 PR，方便 review。

1. **infra**：BigQuery profile + dataset 建立、`dbt_project.yml` 改名與 var 設定、加 `dbt_utils` package。
2. **macros**：新增 `cwa_sentinel_to_null` / `classify_station_type` / `measurement_aggregates`，舊 macro 暫時保留。
3. **staging 重寫**：拆出 `stg_measurements__raw_records`，三個 stg 改 BigQuery JSON 語法。一張一張 PR 並 build + 比對 row count。
4. **intermediate 重寫**：`int_measurements__cleaned`、`int_stations__unioned`。incremental 先用 `--full-refresh` 一次。
5. **dim_stations + mart 4 grain**：依序建立 fct，每張都用 `dbt build` 跑 test 過了再下一張。
6. **舊 model 廢除**：`int_measurements_aggregate_over_datetime`、原 `artifacts/measurements/*` 改 `--alias` 或標 `enabled: false`，跑一週確認無人使用後刪除。
7. **macros 清理**：刪掉 `negative_to_null`、`na_tag_to_null`、四個 rolling window macro。
8. **文件**：補完所有 `_*__models.yml` 的欄位 description，把 `...TBD` 全部補上。

---

## 11. 待確認 / 後續可能擴充

- **JSON 欄位的 BigQuery 載入策略**：是 native JSON type 還是 STRING？這會影響 staging SQL 的 `JSON_VALUE` vs `JSON_EXTRACT_SCALAR`。建議先用 native JSON type。
- **時區**：CWA 提供的時間是台灣時區還是 UTC？建議在 staging 統一轉 UTC 並在 yml 註明。BigQuery `TIMESTAMP` 內部是 UTC，但若資料寫入時被當作 naive，rollup 邊界會錯一個時區。
- **Week 起算日**：BigQuery `TIMESTAMP_TRUNC(ts, WEEK)` 預設週日起算。台灣慣例是週一，需要 `TIMESTAMP_TRUNC(ts, WEEK(MONDAY))`。
- **未來 ML rolling feature**：如果之後資料科學家想要「過去 6 小時平均」這類 row-level feature，可以在 `int_measurements__cleaned` 之後另開一個 `int_measurements__features` model，集中放 rolling window 計算（記得用 `preceding` 不要 `following`）。
- **資料完整性指標**：每個 grain 已加 `observation_count` 與 per-column `*_obs_count`，data scientist 可以直接拿來判斷該 bucket 是否該丟棄（例如 hourly bucket 預期 6 筆，實際 < 4 就視為缺漏）。

---

## 12. Ingestion 補充：GCS + Cloud Run `weather-crawler` 整合

> ⚠️ **REVISION (見 §14)**：本章 §12.2 / §12.3 / §12.6 部分內容基於「BQ 不支援整檔 nested JSON」的誤解寫成；實際上 crawler 用 `json.dumps()` 產出的單行 compact JSON 天然就是合法 NDJSON，BQ 可直接 `bq load --autodetect` 載入並用 `STRUCT` / `ARRAY` 處理 nested + repeated。**請以 §14 為主**，此章節保留為設計過程紀錄。
>
> 本章節依據新版資料管道補充 staging / source 設計。**取代** §3.5（無）、**修訂** §4 的 source 引用。
>
> 上游：[`weather-crawler`](../weather-crawler/) — FastAPI on Cloud Run，由 Cloud Scheduler 定時觸發，將 CWA / 農業 API 回應原文直寫 GCS。

### 12.1 Crawler 落檔規格（事實）

| Endpoint | GCS 路徑 | 觸發頻率 | 內容來源 |
|---|---|---|---|
| `GET /v1/weather` | `gs://{BUCKET}/weather_data/{YYYY-MM-DD}/{HH_MM}.json` | 每 10 分鐘 | CWA O-A0003-001 全台測站當下觀測 |
| `GET /v1/weather_station?stn_type=manned` | `gs://{BUCKET}/weather_station/manned/{YYYY-MM-DD}/{HH_MM}.json` | 每日 | CWA C-B0074-001 有人站 metadata |
| `GET /v1/weather_station?stn_type=unmanned` | `gs://{BUCKET}/weather_station/unmanned/{YYYY-MM-DD}/{HH_MM}.json` | 每日 | CWA C-B0074-002 無人站 metadata |
| `GET /v1/rain_fall_station` | `gs://{BUCKET}/rain_fall/{YYYY-MM-DD}/{HH_MM}.json` | 每日 | 農業雨量站 metadata |

每個 JSON 物件被 crawler 注入一個 top-level 欄位（[api.py:26-31](../weather-crawler/weather_crawler/api.py#L26-L31)）：

```json
{ ...原始 API 回應..., "ingested_at": "YYYY-MM-DD_HH_MM" }
```

這是非標準時間格式。下游解析統一用 `parse_timestamp('%Y-%m-%d_%H_%M', ...)`。

> 對 dbt 而言這非常有價值：`ingested_at` 是 source freshness 的天然 watermark，且未來 crawler 補抓資料時可拿來做 dedup tiebreaker。

### 12.2 Bronze 載入策略：三選一

| 方案 | 簡述 | 優 | 缺 | 推薦 |
|---|---|---|---|---|
| **A. BigQuery External Table（GCS 直讀）** | 用 `dbt-external-tables` 在 BigQuery 建外部表，指向 GCS prefix | 不改 crawler、單一資料源、無資料複製 | 每次 dbt run 重新 list GCS、查詢成本隨檔案量線性 | ✅ 現階段 |
| B. Cloud Storage → BigQuery Data Transfer Service（BQDTS） | GCP 內建排程把 GCS 載到 native BQ 表 | 查詢快、native partition | 多一層 infra、配置稍繁、JSON schema 演化要小心 | 中期（資料量上萬檔/天時）|
| C. 改 crawler 雙寫（GCS + BigQuery） | Crawler 落 GCS 同時 stream insert 到 BQ | 即時可查 | crawler 與 schema 強耦合，違反單一職責 | 不建議 |

採 **方案 A**。Staging view 從 external table 讀，intermediate / mart 維持 incremental table。掃 GCS 的成本只在 dbt run 一次性付出，下游 ad-hoc 查詢吃 native table 不受影響。

### 12.3 路徑設計：建議 crawler 改 hive 命名

Crawler 現行路徑 `weather_data/{date}/{hhmm}.json` **不是 hive-style**（缺 `key=value`），BigQuery 無法做 partition pruning。兩個應對：

**作法 A（短期）**：用 `_FILE_NAME` pseudo column 在 staging view 萃取：
```sql
regexp_extract(_FILE_NAME, r'/(\d{4}-\d{2}-\d{2})/') as ingest_date
```
優：crawler 不變。缺：**partition pruning 無效**，每次都掃整個 prefix。

**作法 B（推薦長期）**：crawler 改 hive 命名，BQ external table 啟用 `hive_partition_uri_prefix`：
```python
# weather-crawler/weather_crawler/api.py:76 等三處
blob_name = f"weather_data/dt={date}/hhmm={date_hhmm}.json"
```
之後 `WHERE dt >= '2026-05-01'` 會真實 prune partition。Crawler 變更僅 1 行 × 4 處。

**建議分階段**：
1. **第一階段**：staging 用作法 A，先把 dbt 整體跑通。
2. **第二階段（資料量累積到萬檔級）**：crawler PR 改 hive 命名，舊資料用 `gsutil mv` 一次性遷移；dbt 改 `hive_partition_uri_prefix`。

> 衡量門檻：當 `weather_data/` 累積超過 ~30 天（≈4,300 個檔案）時，list 操作會明顯變慢，這時值得做第二階段。

### 12.4 dbt 套件與設定

`packages.yml`（新增）：
```yaml
packages:
  - package: dbt-labs/dbt_external_tables
    version: [">=0.10.0", "<1.0.0"]
  - package: dbt-labs/dbt_utils
    version: [">=1.1.0", "<2.0.0"]
```

`dbt_project.yml` 加：
```yaml
dispatch:
  - macro_namespace: dbt_external_tables
    search_order: ['dbt_external_tables']
```

External table DDL 由 dbt 管理，每次 schema 或 location 變動執行：
```bash
dbt run-operation stage_external_sources --vars 'ext_full_refresh: true'
```
建議排在 CI 部署 pipeline 第一步，正式 `dbt build` 之前。

### 12.5 Sources YAML（新版完整）

`models/staging/_sources.yml`：

```yaml
version: 2

sources:
  - name: weather_raw
    database: "{{ env_var('GCP_PROJECT_ID') }}"
    schema: weather_raw                     # 對應 BigQuery dataset
    description: |
      Raw JSON dropped to GCS by the weather-crawler Cloud Run service.
      Each row is one JSON file; `value` column holds the full payload
      with a top-level `ingested_at: 'YYYY-MM-DD_HH_MM'` injected by the crawler.

    # 預設 freshness 規則 — 各表可覆寫
    loaded_at_field: parse_timestamp('%Y-%m-%d_%H_%M', json_value(value, '$.ingested_at'))
    freshness:
      warn_after:  { count: 30, period: minute }
      error_after: { count: 90, period: minute }

    tables:
      # ----- 觀測資料：10 分鐘級 -----
      - name: ext_weather_observations
        description: "CWA O-A0003-001 — 全台測站每 10 分鐘觀測。"
        external:
          location: "gs://{{ env_var('GCS_BUCKET') }}/weather_data/dt=*/hhmm=*.json"   # 第二階段
          # 第一階段（crawler 未改）改用：
          # location: "gs://{{ env_var('GCS_BUCKET') }}/weather_data/*/*.json"
          options:
            format: json
            hive_partition_uri_prefix: "gs://{{ env_var('GCS_BUCKET') }}/weather_data/"
            require_hive_partition_filter: false
        columns:
          - name: dt
            description: Hive partition — 觀測拉取日期 (YYYY-MM-DD)
          - name: hhmm
            description: Hive partition — 觀測拉取時分 (HH_MM)
          - name: value
            description: Raw JSON payload + crawler `ingested_at`.

      # ----- 站別 metadata：日級 -----
      - name: ext_weather_stations_manned
        description: "CWA C-B0074-001 — 有人測站 metadata snapshot。"
        freshness: { warn_after: { count: 36, period: hour } }
        external:
          location: "gs://{{ env_var('GCS_BUCKET') }}/weather_station/manned/*/*.json"
          options: { format: json }

      - name: ext_weather_stations_unmanned
        description: "CWA C-B0074-002 — 無人測站 metadata snapshot。"
        freshness: { warn_after: { count: 36, period: hour } }
        external:
          location: "gs://{{ env_var('GCS_BUCKET') }}/weather_station/unmanned/*/*.json"
          options: { format: json }

      - name: ext_rain_fall_stations
        description: "農業雨量站 metadata snapshot（data.moa.gov.tw）。"
        freshness: { warn_after: { count: 36, period: hour } }
        external:
          location: "gs://{{ env_var('GCS_BUCKET') }}/rain_fall/*/*.json"
          options: { format: json }
```

設計重點：
- `database` / `schema` 用 `env_var`，多環境（dev/prod）共用同份 yml。
- `loaded_at_field` 拿 JSON 內的 `ingested_at`，不依賴 `_FILE_MODIFICATION_TIME` — 重跑 / 補資料時邏輯一致。
- 觀測表 freshness 嚴（30/90 分鐘），metadata 寬（36 小時）。

### 12.6 Staging 模型（修訂版）

#### 12.6.1 `stg_measurements__raw_records.sql`（取代 §4.1）

```sql
{{ config(materialized='view') }}

with src as (
    select
        dt,                                                                        -- hive partition
        hhmm,
        value,
        parse_timestamp('%Y-%m-%d_%H_%M', json_value(value, '$.ingested_at')) as ingest_at
    from {{ source('weather_raw', 'ext_weather_observations') }}
),

flattened as (
    -- CWA 結構：{records: {Station: [...]}, ingested_at: "..."}
    -- 顯式取 records.Station，不再依賴雙層通用 flatten
    select
        s.dt,
        s.ingest_at,
        record
    from src s,
        unnest(json_query_array(s.value, '$.records.Station')) as record
)

select * from flattened
```

關鍵變化：
- `ingest_at` 一路帶到下游，作為 `int_measurements__cleaned` dedup 的 **tiebreaker**（解決原 SQL `ROW_NUMBER ORDER BY measure_at` 的非確定性）。
- JSON path 從通用 `lateral flatten` 改顯式 `$.records.Station` — 結構假設外顯化。
- `dt` 留在 view 中，下游 incremental WHERE 可額外加 `dt >= ...` 達成 partition pruning。

#### 12.6.2 `stg_measurements__observations.sql`（修訂）

主體 SQL 同 §4.2，但多帶兩個欄位：

```sql
select
    -- ... 原本所有欄位 ...
    timestamp(json_value(record, '$.ObsTime.DateTime')) as measure_at,
    ingest_at,                                          -- ← 新增
    dt                                                  -- ← 新增（incremental partition prune）
from {{ ref('stg_measurements__raw_records') }}
```

#### 12.6.3 `stg_weather_stn__stations.sql`（重寫，合併 manned + unmanned）

新版 crawler 把 manned 與 unmanned 寫到不同路徑、不同 source。staging 在這裡 union 並取每站最新一筆 snapshot：

```sql
{{ config(materialized='view') }}

with manned as (
    select
        'manned' as ingest_source,
        parse_timestamp('%Y-%m-%d_%H_%M', json_value(value, '$.ingested_at')) as ingest_at,
        record
    from {{ source('weather_raw', 'ext_weather_stations_manned') }} src,
        unnest(json_query_array(src.value, '$.records.data.stationStatus.station')) as record
),

unmanned as (
    select
        'unmanned' as ingest_source,
        parse_timestamp('%Y-%m-%d_%H_%M', json_value(value, '$.ingested_at')) as ingest_at,
        record
    from {{ source('weather_raw', 'ext_weather_stations_unmanned') }} src,
        unnest(json_query_array(src.value, '$.records.data.stationStatus.station')) as record
),

combined as (
    select * from manned
    union all
    select * from unmanned
),

latest as (
    -- metadata 為 SCD-1 慢變維度，每個 station 只保留最新 snapshot；
    -- 若需要保留歷史變更，改用 dbt snapshot 處理（snapshots/ 資料夾）。
    select * except(rn)
    from (
        select *,
               row_number() over (
                   partition by json_value(record, '$.StationID')
                   order by ingest_at desc
               ) as rn
        from combined
    )
    where rn = 1
)

select
    json_value(record, '$.StationID')                                       as station_id,
    nullif(json_value(record, '$.OriginalStationID'), '')                   as original_station_id,
    nullif(json_value(record, '$.NewStationID'), '')                        as new_station_id,
    json_value(record, '$.status')                                          as station_status,
    json_value(record, '$.StationName')                                     as station_name,
    json_value(record, '$.StationNameEN')                                   as station_name_en,
    json_value(record, '$.CountyName')                                      as county_name,
    json_value(record, '$.Location')                                        as location,
    nullif(json_value(record, '$.Notes'), '')                               as notes,
    safe_cast(json_value(record, '$.StationAltitude')  as float64)          as station_altitude,
    safe_cast(json_value(record, '$.StationLongitude') as float64)          as station_longitude,
    safe_cast(json_value(record, '$.StationLatitude')  as float64)          as station_latitude,
    safe_cast(nullif(json_value(record, '$.StationStartDate'), '') as date) as start_at,
    safe_cast(nullif(json_value(record, '$.StationEndDate'),   '') as date) as end_at,
    ingest_source,                                                           -- 'manned' | 'unmanned'
    ingest_at
from latest
```

要點：
- `union all` 後依 `ingest_at desc` 取每站最新。
- `ingest_source` 留下，給 `dim_stations` 補一個「站別來源」訊息，未來除錯有用。
- 原本 `nullif(...,'')` 取代了現行的 CASE WHEN 空字串判斷，更精煉。
- 全部數值改 `safe_cast`，避免單筆爛資料炸整批。

#### 12.6.4 `stg_rain_fall_stn__stations.sql`（修訂）

結構同上但 source 換成 `ext_rain_fall_stations`、JSON path 換成 `$.Data`。也加上 `ingest_at` + dedup（每站最新）。

### 12.7 Incremental 邏輯：使用 `dt` + `ingest_at`

`int_measurements__cleaned` 與所有 `fct_measurements_*` 的 incremental WHERE 多加一個分區條件，把 BigQuery scan 限縮到必要 partition：

```sql
{% if is_incremental() %}
where measure_at >= timestamp_sub(
        (select max(measure_at) from {{ this }}),
        interval {{ var('measurements_lookback_days') }} day
      )
  -- 額外限制 source 端 partition（若 staging 帶了 dt）
  and dt >= format_date('%Y-%m-%d',
        date_sub(date(_dbt_max_partition), interval {{ var('measurements_lookback_days') }} day))
{% endif %}
```

> `_dbt_max_partition` 是 dbt-bigquery 提供的內建變數（partitioned incremental）。

dedup ORDER BY 改：
```sql
row_number() over (
    partition by station_id, measure_at
    order by ingest_at desc          -- 最新拉到的版本勝出
) as rn
```
這讓 crawler 補抓 / 重發時自然收斂到最新版本。

### 12.8 監控與告警

```bash
# 排在 Cloud Scheduler 每小時跑一次（或 GitHub Actions schedule）
dbt source freshness --select source:weather_raw
```

失敗條件：
- `ext_weather_observations`：90 分鐘無新檔 → error（crawler 掛了）
- 三個 station metadata：36 小時無新檔 → warn

dbt 的 `target/sources.json` 可餵到 Slack / Discord webhook 做告警。

### 12.9 Crawler 端建議改動清單

依優先級排序：

| 優先 | 改動 | 影響 | 對應變動 |
|---|---|---|---|
| **High** | `weather_data/` 路徑改 hive (`dt={date}/hhmm={hhmm}.json`) | BQ partition pruning 才會生效，第二階段必做 | [api.py:76](../weather-crawler/weather_crawler/api.py#L76) 改 1 行 |
| **High** | `ingested_at` 格式改 ISO 8601 (`2026-05-08T14:30:00+08:00`) | 下游不用每次 `parse_timestamp`，且帶 timezone（解 §11 時區疑問） | [api.py:26-31](../weather-crawler/weather_crawler/api.py#L26-L31) |
| Medium | 增加 `crawler_version`（git sha 或 image tag）注入 | 資料血緣追蹤 / 異動排查 | api.py 加 1 行 |
| Medium | 增加 `request_id`（uuid）注入 | 跨 log / GCS / BQ 串流追蹤 | api.py 加 1 行 |
| Low | 觀測 endpoint 比對 `Last-Modified` 或前次 hash，相同就不寫檔 | 省 GCS 寫入 + 下游 dedup 工作量 | api.py 中等改動 |

> §11 第二項「時區」疑問：CWA `ObsTime.DateTime` 預設台灣時間且**沒有 timezone offset**。建議在 staging 統一 `timestamp(..., 'Asia/Taipei')` 明確標時區，且 crawler 的 `ingested_at` 也應帶 offset（上方 High 優先項）。

### 12.10 對應 §11 待確認事項更新

| 原 §11 項目 | 狀態 |
|---|---|
| JSON 欄位的 BigQuery 載入策略 | ✅ 解決：external table 用 `format=json`，`value` 為 BigQuery JSON type，下游一律 `json_value` / `json_query_array` |
| 時區 | 🟡 部分解決：建議 crawler 改 ISO 8601 帶 offset；staging 顯式 `Asia/Taipei`（見 §12.9） |
| Week 起算日 | 🔴 未決：仍待確認台灣慣例週一起算 → mart 用 `TIMESTAMP_TRUNC(ts, WEEK(MONDAY))` |
| ML rolling feature | 🔴 未決：等使用者需求 |
| 資料完整性指標 | ✅ 已涵蓋於 §6.1 macro |

---

## 13. Orchestration：dbt 與 crawler 解耦，週批次

> **更新（實作後）**：原始設計提出每日批次（02:00），落地時改為 **每週一 02:30 Asia/Taipei** 一次。
> 對應 Cloud Run Job 重命名為 `dbt-weekly-build`，`measurements_lookback_days` 由 5 提升為 10
> （= 7 天 cadence + 3 天遲到緩衝）。本節保留原本「每日」的設計推論作為歷史記錄，
> 但所有具名 artifact（cron、job 名、lookback 值）皆以 [`infra/dbt/`](../infra/dbt/) 與
> [`weather_data_dbt/dbt_project.yml`](../weather_data_dbt/dbt_project.yml) 為實作真實。
>
> 目標：dbt 從 crawler 完全解耦，**每週跑一次** mart 重算，但維持 crawler 失效的快速偵測能力。

### 13.1 排程拓撲

三個獨立排程，彼此不互相觸發、不共享狀態，僅以 GCS（兩者）/ BigQuery source freshness（觀察者）為**事實邊界**：

```
時間軸 (Asia/Taipei)
─────────────────────────────────────────────────────────────────
00:00  01:00  02:00  03:00  04:00  ...  10:00       23:50  00:00
   │      │      │      │      │      │      │           │
   ▼      ▼      ▼      ▼      ▼      ▼      ▼           ▼
   ●      ●      ●      ●      ●      ●      ●  ......   ●     ← Crawler /10min
                 ┃
                 ┗━━━ dbt build (daily, 02:00)
   ▲      ▲      ▲      ▲      ▲      ▲      ▲           ▲
   │      │      │      │      │      │      │           │
   └──────┴──────┴──────┴──────┴──────┴──────┴───────────┘
                          dbt source freshness (hourly)
```

| 排程 | 頻率 | 工作 | 失敗影響 | 失敗復原 |
|---|---|---|---|---|
| **A. Crawler** | 每 10 分鐘 | 抓 API → 寫 GCS | 缺一個 10 分鐘 snapshot；下次成功即補上 | Cloud Run 自動重試；超過 90 分無新檔由 (B) 偵測 |
| **B. Source freshness** | 每小時 | `dbt source freshness` → 推播 | 無資料影響；僅監控盲點 | 排程獨立，自身監控用 GCP Cloud Monitoring 兜底 |
| **C. dbt build** | 每日 02:00 | `dbt build`（incremental + lookback） | mart 落後 1 天 | 隔日自動補（因 lookback 涵蓋）；緊急可手動觸發 |

關鍵設計：**(B) 與 (C) 都用 dbt，但走不同 Cloud Run Job、不同排程、不同 SLO**。把監控與生產跑分離，避免 build 慢拖累告警時效。

### 13.2 為什麼選 Cloud Run Job

| 候選 | 月成本 | 適合度 | 排除理由 |
|---|---|---|---|
| **Cloud Run Job + Cloud Scheduler** | ~$0–2 | ⭐⭐⭐⭐⭐ | — |
| Cloud Composer (Airflow) | $300+ | ⭐⭐ | always-on、單 DAG 殺雞用牛刀 |
| GitHub Actions cron | $0（公開 repo）| ⭐⭐⭐ | Secrets / 跨 cloud egress 麻煩；非生產取向 |
| dbt Cloud | $100+ | ⭐⭐⭐ | 月費高、與 GCP 體系脫鉤 |
| GCE + cron | ~$10 | ⭐ | always-on、無重試、無監控 |

Cloud Run Job 的優勢：
- 與 crawler 共用 infra paradigm（[`weather-crawler/Dockerfile`](../weather-crawler/Dockerfile) 風格延伸）
- 按執行計費，不跑不收錢
- Workload Identity 直接拿 BQ 權限，不用管 service account key 檔案
- 失敗自動重試（`--max-retries`）
- 日誌進 Cloud Logging，與 crawler 同一面板

### 13.3 Image 設計

`infra/dbt/Dockerfile`：
```dockerfile
FROM ghcr.io/dbt-labs/dbt-bigquery:1.8.latest

WORKDIR /workspace

# 複製 dbt 專案
COPY weather_data_dbt/ ./weather_data_dbt/

# 預先 install packages（dbt-external-tables / dbt-utils）
WORKDIR /workspace/weather_data_dbt
RUN dbt deps --profiles-dir /workspace/weather_data_dbt/profiles

# 預設 entrypoint 為 dbt，args 由 Cloud Run Job 傳入
ENTRYPOINT ["dbt"]
```

`weather_data_dbt/profiles/profiles.yml`（用 env var 注入）：
```yaml
weather_data_dbt:
  target: prod
  outputs:
    prod:
      type: bigquery
      method: oauth                       # Workload Identity 自動取得 token
      project: "{{ env_var('GCP_PROJECT_ID') }}"
      dataset: "{{ env_var('DBT_DATASET', 'analytics') }}"
      location: "{{ env_var('BQ_LOCATION', 'asia-east1') }}"
      threads: 4
      timeout_seconds: 1800
      priority: batch                      # 用 batch slot 省成本
      job_retries: 2
```

> `method: oauth` + Workload Identity = 不需要 keyfile。Cloud Run Job 的 service account 自動帶權限。

### 13.4 兩個 Cloud Run Job

#### 13.4.1 `dbt-weekly-build`（週一批次）

```bash
gcloud run jobs create dbt-weekly-build \
  --image="$REGION-docker.pkg.dev/$PROJECT/dbt/weather-dbt:$TAG" \
  --region="$REGION" \
  --service-account="dbt-runner@$PROJECT.iam.gserviceaccount.com" \
  --set-env-vars="GCP_PROJECT_ID=$PROJECT,GCS_BUCKET=$BUCKET,DBT_DATASET=analytics" \
  --task-timeout=45m \
  --cpu=2 --memory=2Gi \
  --max-retries=1 \
  --args="build,--target=prod,--profiles-dir=/workspace/weather_data_dbt/profiles"
```

排程：
```bash
gcloud scheduler jobs create http dbt-weekly-trigger \
  --location="$REGION" \
  --schedule="30 2 * * 1" --time-zone="Asia/Taipei" \
  --uri="https://$REGION-run.googleapis.com/v2/projects/$PROJECT/locations/$REGION/jobs/dbt-weekly-build:run" \
  --http-method=POST \
  --oauth-service-account-email="scheduler-invoker@$PROJECT.iam.gserviceaccount.com"
```

> **時間選擇 02:00 的理由**：
> - 凌晨 GCP slot 競爭少、batch 優先級的 BQ slot 更穩定
> - 距前一日最後一筆 crawler 落檔（23:50）有 2 小時緩衝，讓遲到資料先進到 GCS
> - 失敗也可在 08:00 上班前察覺

#### 13.4.2 `dbt-hourly-freshness`（監控）

```bash
gcloud run jobs create dbt-hourly-freshness \
  --image="$REGION-docker.pkg.dev/$PROJECT/dbt/weather-dbt:$TAG" \
  --region="$REGION" \
  --service-account="dbt-runner@$PROJECT.iam.gserviceaccount.com" \
  --set-env-vars="GCP_PROJECT_ID=$PROJECT,GCS_BUCKET=$BUCKET,WEBHOOK_URL=$WEBHOOK_URL" \
  --task-timeout=5m \
  --cpu=1 --memory=512Mi \
  --max-retries=0 \
  --args="source,freshness,--target=prod,--profiles-dir=/workspace/weather_data_dbt/profiles"
```

排程：`0 * * * * Asia/Taipei`（每整點）。

**告警接線**：dbt 命令完成後產出 `target/sources.json`，包成一個薄的 wrapper script，失敗或 warn 時發 Discord / Slack webhook。

`infra/dbt/freshness_wrapper.sh`：
```bash
#!/usr/bin/env bash
set +e
dbt source freshness "$@"
exit_code=$?

if [ $exit_code -ne 0 ]; then
  # 取最近一次的 max_loaded_at 與 source name 推播
  python /workspace/infra/dbt/post_freshness_alert.py \
      --sources-json target/sources.json \
      --webhook-url "$WEBHOOK_URL"
fi
exit $exit_code
```

把 image entrypoint 改成此 wrapper（仅 freshness job 用）。

### 13.5 IAM 與權限

最小化兩個 service account：

| Service Account | 角色 | 用途 |
|---|---|---|
| `dbt-runner@…` | `roles/bigquery.dataEditor` (analytics dataset) `roles/bigquery.user` (project) `roles/storage.objectViewer` (GCS bucket) | dbt build / freshness 執行身分 |
| `scheduler-invoker@…` | `roles/run.invoker` (兩個 job) | Cloud Scheduler 觸發 Cloud Run Job |

**特別注意**：
- `bigquery.dataEditor` 限制在 `analytics` dataset；`weather_raw`（external table）只給 `dataViewer`。Crawler 用獨立 SA，dbt 不應有寫 GCS 的權限。
- 若使用 hive partition external table，需要對 GCS bucket `roles/storage.objectViewer` 加上 `roles/bigquery.connectionUser`（如果用 BigQuery Connection 作為 external table 認證）。

### 13.6 Terraform 草稿（可選但強烈建議）

`infra/terraform/dbt_orchestration.tf`：
```hcl
locals {
  region   = "asia-east1"
  image    = "${local.region}-docker.pkg.dev/${var.project}/dbt/weather-dbt:${var.image_tag}"
  job_envs = {
    GCP_PROJECT_ID = var.project
    GCS_BUCKET     = var.bucket
    DBT_DATASET    = "analytics"
  }
}

resource "google_service_account" "dbt_runner" {
  account_id   = "dbt-runner"
  display_name = "dbt Cloud Run Job runner"
}

resource "google_project_iam_member" "dbt_bq_user" {
  project = var.project
  role    = "roles/bigquery.user"
  member  = "serviceAccount:${google_service_account.dbt_runner.email}"
}

resource "google_bigquery_dataset_iam_member" "dbt_analytics_editor" {
  dataset_id = "analytics"
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${google_service_account.dbt_runner.email}"
}

resource "google_bigquery_dataset_iam_member" "dbt_raw_viewer" {
  dataset_id = "weather_raw"
  role       = "roles/bigquery.dataViewer"
  member     = "serviceAccount:${google_service_account.dbt_runner.email}"
}

resource "google_storage_bucket_iam_member" "dbt_gcs_viewer" {
  bucket = var.bucket
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.dbt_runner.email}"
}

# --- daily build job ---
resource "google_cloud_run_v2_job" "dbt_weekly_build" {
  name     = "dbt-weekly-build"
  location = local.region

  template {
    template {
      service_account = google_service_account.dbt_runner.email
      timeout         = "2700s"
      max_retries     = 1
      containers {
        image = local.image
        args  = ["build", "--target=prod",
                 "--profiles-dir=/workspace/weather_data_dbt/profiles"]
        dynamic "env" {
          for_each = local.job_envs
          content {
            name  = env.key
            value = env.value
          }
        }
        resources { limits = { cpu = "2", memory = "2Gi" } }
      }
    }
  }
}

# --- hourly freshness job ---
resource "google_cloud_run_v2_job" "dbt_hourly_freshness" {
  name     = "dbt-hourly-freshness"
  location = local.region

  template {
    template {
      service_account = google_service_account.dbt_runner.email
      timeout         = "300s"
      max_retries     = 0
      containers {
        image = local.image
        args  = ["source", "freshness", "--target=prod",
                 "--profiles-dir=/workspace/weather_data_dbt/profiles"]
        dynamic "env" {
          for_each = merge(local.job_envs, { WEBHOOK_URL = var.webhook_url })
          content {
            name  = env.key
            value = env.value
          }
        }
        resources { limits = { cpu = "1", memory = "512Mi" } }
      }
    }
  }
}

# --- scheduler ---
resource "google_service_account" "scheduler_invoker" {
  account_id   = "scheduler-invoker"
  display_name = "Cloud Scheduler → Cloud Run Job invoker"
}

resource "google_cloud_run_v2_job_iam_member" "invoker_build" {
  name     = google_cloud_run_v2_job.dbt_weekly_build.name
  location = local.region
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.scheduler_invoker.email}"
}

resource "google_cloud_run_v2_job_iam_member" "invoker_freshness" {
  name     = google_cloud_run_v2_job.dbt_hourly_freshness.name
  location = local.region
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.scheduler_invoker.email}"
}

resource "google_cloud_scheduler_job" "dbt_weekly" {
  name      = "dbt-weekly-trigger"
  region    = local.region
  schedule  = "30 2 * * 1"
  time_zone = "Asia/Taipei"

  http_target {
    http_method = "POST"
    uri = "https://${local.region}-run.googleapis.com/v2/projects/${var.project}/locations/${local.region}/jobs/${google_cloud_run_v2_job.dbt_weekly_build.name}:run"
    oauth_token {
      service_account_email = google_service_account.scheduler_invoker.email
    }
  }
}

resource "google_cloud_scheduler_job" "dbt_freshness" {
  name      = "dbt-freshness-trigger"
  region    = local.region
  schedule  = "0 * * * *"
  time_zone = "Asia/Taipei"

  http_target {
    http_method = "POST"
    uri = "https://${local.region}-run.googleapis.com/v2/projects/${var.project}/locations/${local.region}/jobs/${google_cloud_run_v2_job.dbt_hourly_freshness.name}:run"
    oauth_token {
      service_account_email = google_service_account.scheduler_invoker.email
    }
  }
}
```

### 13.7 Lookback window 重新評估

週批次（Mon 02:30）+ crawler 偶爾失敗 → lookback 從 §3 預設的 3 天放寬到 **10 天**（= 7 天 cadence + 3 天遲到緩衝）：

```yaml
# dbt_project.yml
vars:
  measurements_lookback_days: 10
```

成本：每週 MERGE 多掃 ~10 天 partition。BigQuery 上單一 partition (1 station × 1 day × 144 records) 約 KB 級，2 萬個 station × 10 天 ≈ 中位 GB 級掃描，**單次成本約 $0.01**。完全可接受。

### 13.8 Backfill / 補資料 Runbook

當 crawler 修復後要補抓歷史，或修了 dbt bug 要重算過去 N 天：

```bash
# 1. 觸發一次性 build，臨時放寬 lookback（在 GCP Console / gcloud 都可）
gcloud run jobs execute dbt-weekly-build \
  --region="$REGION" \
  --update-env-vars="DBT_VARS={\"measurements_lookback_days\": 30}" \
  --args="build,--target=prod,--vars,{measurements_lookback_days: 30},--profiles-dir=/workspace/weather_data_dbt/profiles"

# 2. 若是 schema breaking change（加欄位、改型別），需要 full-refresh
gcloud run jobs execute dbt-weekly-build \
  --region="$REGION" \
  --args="build,--full-refresh,--select,fct_measurements_hourly+,--target=prod,--profiles-dir=/workspace/weather_data_dbt/profiles"
```

**Runbook checklist**：
- [ ] 確認 GCS 對應日期的 raw JSON 都還在（沒被 lifecycle policy 刪掉）
- [ ] 評估 BQ 掃描成本（`--vars 'measurements_lookback_days: 60'` ≠ 免費）
- [ ] 通知下游使用者（mart 重算期間數值會跳動）
- [ ] 手動觸發後檢查 `target/run_results.json` 與 `target/manifest.json`，確認沒有 skipped models
- [ ] 跑完拿 `dbt test --select state:modified+ --state ./previous_state` 驗證

### 13.9 觀測（observability）

最小集合，依優先級：

| 優先 | 訊號 | 訂閱方式 |
|---|---|---|
| **P0** | dbt source freshness error | hourly job 推 Discord/Slack webhook（§13.4.2） |
| **P0** | Cloud Run Job 執行失敗 | Cloud Monitoring alert policy（`run.googleapis.com/job/completed_task_attempt_count` with `result=failed`）→ webhook |
| **P1** | dbt test 失敗（mart 級） | `dbt build` 結尾 hook 檢查 `target/run_results.json`，失敗就推 webhook |
| **P2** | BigQuery slot 耗盡 / 查詢逾時 | Cloud Monitoring 監看 `bigquery.googleapis.com/slots/total_allocated_for_reservation` |
| **P3** | dbt run 持續時間飆高（>30 min） | Cloud Monitoring custom metric，觀察趨勢 |

進階可以引入 [`elementary-data`](https://github.com/elementary-data/elementary)：把 dbt artifacts 寫入 BQ → 自動產生 data freshness / volume / freshness anomaly dashboard。但別在第一版就上，先把 P0/P1 弄穩。

### 13.10 與 §11/§12 連動

- §11 「時區」疑問：dbt build 排程 `time_zone="Asia/Taipei"` 已明確；source 端 `ingested_at` 若改 ISO 8601 帶 offset（§12.9 High 優先項），整條鏈路時區一致。
- §12.7 incremental WHERE 已預留 `dt >= ...` partition pruning，每日跑 + lookback 5 天 → 每次 MERGE 只掃過去 5 個 daily partition，成本可預測。
- §10 遷移步驟在第 5 步（mart 建立完）之後加一個第 5.5 步：「設置 Cloud Run Job + Scheduler，從第一天就讓 dbt 走每日批次，避免 ad-hoc dbt run 的習慣養成」。

### 13.11 取捨清單（接受 / 警覺 / 不接受）

**接受**：
- mart 資料延遲 24 小時（離線 ML 訓練無感）
- dbt run 成本日趨穩定（一日一次）
- Operator 多管一個 Cloud Run Job + Scheduler

**警覺**：
- 若哪天加了 dashboard 或 BI 即時需求，會逼回到較高頻 dbt run。**先不過度設計**。
- GCS 的 raw JSON 要設 lifecycle policy（建議保留 90 天），避免無限累積。Hot/Cold tier 視成本決定。

**不接受**：
- 不要把 dbt build 排在 crawler 同一個 Cloud Run Service 裡（耦合度高、失敗影響範圍大）。
- 不要用 GCE + cron（無重試、無監控、operator 痛苦）。
- 不要把 freshness check 和 daily build 共用同一個 Cloud Run Job（SLO 不同、節奏不同）。

---

## 14. Bulk Load Runbook：歷史資料一次性載入 BigQuery

> 本章節**修訂 §12.2 / §12.3 / §12.6 的部分判斷**。
>
> 起因：先前段落基於「BQ 不支援整檔 nested JSON」的誤解寫成。實際上 crawler 用 `json.dumps()` 產生的是**單行 compact JSON**（[api.py:31](../weather-crawler/weather_crawler/api.py#L31)），每個檔案天然就是合法的 NDJSON record，BQ 可直接 `bq load` + autodetect，並透過 `STRUCT` / `ARRAY<STRUCT>` 完整保留 nested + repeated 結構。**完全不需要 Python 轉檔，也不需要修改 crawler。**
>
> Snowflake 的 `lateral flatten` 是 Snowflake 特有能力；BQ 對應的是 `UNNEST(array_column)`，效率與表達力俱佳。

### 14.1 對 §12 的修正摘要

| §12 段落 | 原本說法 | 實際情況 |
|---|---|---|
| §12.2 plan A (external table) | 推薦先用 | 對 12 萬檔級規模 list 太慢，**不建議** |
| §12.2 plan B (BQDTS) | "中期可考慮" | 不需要 BQDTS——`bq load` 兩三條命令搞定 |
| §12.2 plan C (改 crawler) | 不建議 | 確實不建議，且**完全不必改 crawler** |
| §12.3 hive partition | "為 partition pruning 必須改 crawler" | bronze native table 已 partition；hive 命名變成 nice-to-have |
| §12.6 staging 兩層拆分 | `raw_records` + `observations` 兩個 view | bronze 已 flatten，**staging 一層即可**（見 §14.8） |

新架構：
```
GCS (raw nested JSON, crawler 產出)
       │
       │ (1) bq load --source_format=NEWLINE_DELIMITED_JSON --autodetect
       ▼
weather_raw.observations_staging   (BQ native, 保留 nested 結構)
       │
       │ (2) UNNEST(records.Station) + 重組
       ▼
weather_raw.observations           (BQ native, 一行一觀測, partition+cluster)
       │
       │ dbt staging (view, 只做 sentinel + rename)
       ▼
stg_measurements__observations
       │
       ▼
int / fct ...
```

### 14.2 前置作業

```bash
# 1. 建立 dataset
bq mk --dataset --location=asia-east1 \
  side-project-weather:weather_raw

# 2. 確認認證
gcloud auth login
gcloud config set project side-project-weather

# 3. 量一下實際規模
gsutil du -sh gs://side-project-weather-data/
gsutil ls -r 'gs://side-project-weather-data/weather_data/*/*.json' | wc -l
```

### 14.3 Step 1：載入 staging table（保留 nested）

讓 BQ autodetect schema，得到一張保留原始 nested 結構的 staging 表：

```bash
bq load \
  --source_format=NEWLINE_DELIMITED_JSON \
  --autodetect \
  --replace \
  weather_raw.observations_staging \
  'gs://side-project-weather-data/weather_data/*/*.json'
```

設計要點：
- `--autodetect`：對 NESTED + REPEATED 推得很可靠；CWA API 結構穩定。
- `--replace`：bulk load 是冪等的，重跑不會重複。
- glob 用 `*/*.json` 而不是 `**/*.json`：BQ 對單層 wildcard 處理較快；如果未來目錄深度增加再改。

預期時間：12 萬個小檔約 **10–30 分鐘**（受 GCS list 速度影響較大）。

驗證：
```sql
-- 看 schema 是否正確展開
SELECT column_name, data_type
FROM weather_raw.INFORMATION_SCHEMA.COLUMNS
WHERE table_name = 'observations_staging'
ORDER BY ordinal_position;

-- 確認 row 數（應約等於檔案數，每檔一筆）
SELECT COUNT(*) AS files_loaded FROM weather_raw.observations_staging;

-- 抽樣看 records.Station 的長度
SELECT
  ARRAY_LENGTH(records.Station) AS stations_per_file,
  COUNT(*) AS file_count
FROM weather_raw.observations_staging
GROUP BY stations_per_file
ORDER BY stations_per_file DESC
LIMIT 20;
```

### 14.4 Step 2：UNNEST + 重組到 partitioned bronze

bronze 改成「一行 = 一觀測」的扁平結構，partition + cluster 才能發揮：

```sql
CREATE TABLE weather_raw.observations
PARTITION BY measure_date
CLUSTER BY station_id, station_type
AS
SELECT
  -- ids
  station.StationId    AS station_id,
  station.StationName  AS station_name,

  -- numerics（保留原始值，sentinel 處理交給 dbt staging）
  station.WeatherElement.AirTemperature                     AS air_temperature,
  station.WeatherElement.AirPressure                        AS air_pressure,
  station.WeatherElement.RelativeHumidity                   AS relative_humidity,
  station.WeatherElement.WindSpeed                          AS wind_speed,
  station.WeatherElement.WindDirection                      AS wind_direction,
  station.WeatherElement.GustInfo.PeakGustSpeed             AS peak_gust_speed,
  station.WeatherElement.GustInfo.Occurred_at.WindDirection AS wind_direction_gust,
  station.WeatherElement.Now.Precipitation                  AS precipitation,
  station.WeatherElement.SunshineDuration                   AS sunshine_duration_10min,
  station.WeatherElement.UVIndex                            AS uv_index,

  -- strings
  station.WeatherElement.Weather                            AS weather_status,
  station.WeatherElement.VisibilityDescription              AS visibility,

  -- geo
  station.GeoInfo.CountyName     AS county_name,
  station.GeoInfo.CountyCode     AS county_code,
  station.GeoInfo.TownName       AS town_name,
  station.GeoInfo.TownCode       AS town_code,
  station.GeoInfo.StationAltitude AS station_altitude,

  -- timestamps（時區假設 Asia/Taipei，§11 待確認）
  TIMESTAMP(station.ObsTime.DateTime, 'Asia/Taipei')        AS measure_at,
  DATE(station.ObsTime.DateTime, 'Asia/Taipei')             AS measure_date,
  PARSE_TIMESTAMP('%Y-%m-%d_%H_%M', ingested_at)            AS ingest_at,

  -- station classification（一次計算，下游不用 macro）
  CASE
    WHEN STARTS_WITH(station.StationId, '46') THEN '有人站'
    WHEN STARTS_WITH(station.StationId, 'C0')
      OR STARTS_WITH(station.StationId, 'C1') THEN '自動站'
    ELSE '農業雨量站'
  END AS station_type

FROM weather_raw.observations_staging,
UNNEST(records.Station) AS station;
```

驗證：
```sql
SELECT
  COUNT(*)                                AS total_rows,
  COUNT(DISTINCT station_id)              AS unique_stations,
  MIN(measure_at)                         AS earliest,
  MAX(measure_at)                         AS latest,
  COUNT(DISTINCT measure_date)            AS days_covered,
  COUNTIF(air_temperature IS NULL)        AS null_temp,
  COUNTIF(air_temperature IN (-99,-999))  AS sentinel_temp
FROM weather_raw.observations;
```

預期：
- total_rows ≈ 9 千萬（120K 檔 × ~700 站）
- days_covered ≈ 860 (2024-01-01 到今天)
- sentinel_temp 應該有相當數量（缺值點）

### 14.5 Step 3：清掉 staging table

```sql
DROP TABLE weather_raw.observations_staging;
```

省下 ~6GB 儲存（價值雖然只是幾分錢/月，但維護衛生比較重要）。

### 14.6 Station metadata 三張表的同步處理

跟 weather_data 不同，metadata 一天才一個檔，但仍用相同 pattern：

```bash
# Manned weather stations
bq load --source_format=NEWLINE_DELIMITED_JSON --autodetect --replace \
  weather_raw.weather_stations_manned_staging \
  'gs://side-project-weather-data/weather_station/manned/*/*.json'

# Unmanned weather stations
bq load --source_format=NEWLINE_DELIMITED_JSON --autodetect --replace \
  weather_raw.weather_stations_unmanned_staging \
  'gs://side-project-weather-data/weather_station/unmanned/*/*.json'

# Rain fall stations
bq load --source_format=NEWLINE_DELIMITED_JSON --autodetect --replace \
  weather_raw.rain_fall_stations_staging \
  'gs://side-project-weather-data/rain_fall/*/*.json'
```

UNNEST 路徑：
- CWA stations：`UNNEST(records.data.stationStatus.station)`
- 農業雨量站：`UNNEST(Data)`

每張 staging 跑一次 `CREATE TABLE ... AS SELECT ... FROM staging, UNNEST(...)` 出 flatten table。每站只保留最新一筆 snapshot：

```sql
CREATE TABLE weather_raw.weather_stations
CLUSTER BY station_id
AS
WITH manned AS (
  SELECT 'manned' AS source, station, PARSE_TIMESTAMP('%Y-%m-%d_%H_%M', ingested_at) AS ingest_at
  FROM weather_raw.weather_stations_manned_staging,
  UNNEST(records.data.stationStatus.station) AS station
),
unmanned AS (
  SELECT 'unmanned' AS source, station, PARSE_TIMESTAMP('%Y-%m-%d_%H_%M', ingested_at) AS ingest_at
  FROM weather_raw.weather_stations_unmanned_staging,
  UNNEST(records.data.stationStatus.station) AS station
),
combined AS (
  SELECT * FROM manned UNION ALL SELECT * FROM unmanned
),
latest AS (
  SELECT * EXCEPT(rn) FROM (
    SELECT *,
      ROW_NUMBER() OVER (PARTITION BY station.StationID ORDER BY ingest_at DESC) AS rn
    FROM combined
  ) WHERE rn = 1
)
SELECT
  station.StationID AS station_id,
  NULLIF(station.OriginalStationID, '') AS original_station_id,
  NULLIF(station.NewStationID, '')      AS new_station_id,
  station.status                        AS station_status,
  station.StationName                   AS station_name,
  station.StationNameEN                 AS station_name_en,
  station.CountyName                    AS county_name,
  station.Location                      AS location,
  NULLIF(station.Notes, '')             AS notes,
  station.StationAltitude               AS station_altitude,
  station.StationLongitude              AS station_longitude,
  station.StationLatitude               AS station_latitude,
  SAFE.PARSE_DATE('%Y-%m-%d', NULLIF(station.StationStartDate, '')) AS start_at,
  SAFE.PARSE_DATE('%Y-%m-%d', NULLIF(station.StationEndDate, ''))   AS end_at,
  source AS ingest_source,
  ingest_at
FROM latest;
```

跑完同樣 `DROP TABLE` staging。

### 14.7 持續性 ingestion：每日 Cloud Run Job

> **實作落地**：原始設計於本節提出 Cloud Run Job；中途曾考慮以 BigQuery Scheduled Query 簡化部署，
> 最終回到 Cloud Run Job 路線。實際成品見 [`infra/bq/Dockerfile`](../infra/bq/Dockerfile)、
> [`infra/bq/deploy_jobs.sh`](../infra/bq/deploy_jobs.sh)、[`infra/bq/daily_load.sh`](../infra/bq/daily_load.sh)
> 與 GHA 自動化 [`.github/workflows/bq_cd.yml`](../.github/workflows/bq_cd.yml)。
> Job 名稱為 `bronze-daily-load`，runtime SA 為 `bronze-loader@…`。

`infra/bq/daily_load.sh`（在 Cloud Run Job 裡跑，搭 §13 排程）：

```bash
#!/usr/bin/env bash
set -euo pipefail

YESTERDAY="${YESTERDAY:-$(date -u -d 'yesterday' +%Y-%m-%d)}"
PROJECT="${GCP_PROJECT_ID}"
BUCKET="${GCS_BUCKET}"

# 1. 載入昨日全量到 daily staging（覆寫）
bq load \
  --source_format=NEWLINE_DELIMITED_JSON --autodetect --replace \
  "${PROJECT}:weather_raw.observations_daily_staging" \
  "gs://${BUCKET}/weather_data/${YESTERDAY}/*.json"

# 2. MERGE 到 partitioned bronze（idempotent，遲到資料安全）
bq query --use_legacy_sql=false "
MERGE \`${PROJECT}.weather_raw.observations\` AS target
USING (
  SELECT
    station.StationId AS station_id,
    -- ... 同 §14.4 的所有 SELECT 欄位 ...
  FROM \`${PROJECT}.weather_raw.observations_daily_staging\`,
  UNNEST(records.Station) AS station
) AS source
ON target.station_id = source.station_id
   AND target.measure_at = source.measure_at
WHEN MATCHED THEN UPDATE SET
  air_temperature = source.air_temperature,
  -- ... 其他欄位 ...
  ingest_at = source.ingest_at
WHEN NOT MATCHED THEN INSERT ROW
"

# 3. 清掉 daily staging
bq query --use_legacy_sql=false "
DROP TABLE \`${PROJECT}.weather_raw.observations_daily_staging\`
"
```

要點：
- `MERGE` 取代簡單 `INSERT`，遲到資料 / 重跑無副作用
- `observations_daily_staging` 每天 `--replace`，不用保留歷史
- Cloud Run Job timeout 5–10 分鐘綽綽有餘（每天 144 檔）

排程：交給 §13.4.1 的同一個 Cloud Scheduler，把這份 shell 包進 image 入口點即可。Crawler **完全不用動**——bronze load 純粹是下游 transformation，crawler 持續走原本 `weather_data/{date}/{hhmm}.json` 的落檔模式。

### 14.8 對 dbt staging 的簡化（取代 §12.6）

bronze 已 flatten，§12.6 的兩層 view 合併成一張：

```sql
-- models/staging/measurements/stg_measurements__observations.sql
{{ config(materialized='view') }}

{%- set numeric_columns = [
    'air_temperature', 'air_pressure', 'relative_humidity',
    'wind_speed', 'wind_direction', 'wind_direction_gust',
    'peak_gust_speed', 'precipitation', 'sunshine_duration_10min',
    'uv_index'
] -%}

select
    -- ids
    station_id,
    station_name,
    station_type,

    -- geo
    county_name,
    county_code,
    town_name,
    town_code,
    station_altitude,

    -- numerics (sentinel → null)
    {% for col in numeric_columns -%}
    {{ cwa_sentinel_to_null(col) }} as {{ col }},
    {% endfor %}

    -- strings (sentinel → null)
    nullif(weather_status, '-99') as weather_status,
    nullif(visibility,     '-99') as visibility,

    -- timestamps
    measure_at,
    measure_date,
    ingest_at

from {{ source('weather_raw', 'observations') }}
```

對應 source yml：

```yaml
# models/staging/_sources.yml
version: 2

sources:
  - name: weather_raw
    database: "{{ env_var('GCP_PROJECT_ID') }}"
    schema: weather_raw
    loaded_at_field: ingest_at
    freshness:
      warn_after:  { count: 30, period: minute }
      error_after: { count: 90, period: minute }
    tables:
      - name: observations
        description: |
          One row per (station, observation timestamp). Loaded from GCS via
          `bq load + UNNEST` (see redesign_proposal.md §14). Sentinel values
          (-99, -999) preserved verbatim — dbt staging cleans them.
      - name: weather_stations
        description: |
          Latest snapshot per station (manned + unmanned merged). See §14.6.
        loaded_at_field: ingest_at
        freshness: { warn_after: { count: 36, period: hour } }
      - name: rain_fall_stations
        description: |
          Latest snapshot of agricultural rain-fall stations.
        loaded_at_field: ingest_at
        freshness: { warn_after: { count: 36, period: hour } }
```

幾個重要的「**節省**」：
- `stg_measurements__raw_records` 整個刪除——bronze 已 flatten。
- `stg_measurements__station_geo` 也不用了——geo 欄位已在 bronze 同一張表。
- staging 不再依賴 `dbt-external-tables` package（純 native source）。
- `loaded_at_field` 直接用 `ingest_at`（已是 TIMESTAMP），不用每次 `parse_timestamp`。

### 14.9 對 §11 待確認事項的影響

| §11 項目 | 狀態 |
|---|---|
| JSON 載入策略 | ✅ 終於確定：bq load + autodetect + UNNEST |
| 時區 | 🟡 bronze SQL 的 `TIMESTAMP(..., 'Asia/Taipei')` 需要你確認 CWA `ObsTime.DateTime` 是 naive Asia/Taipei；若 crawler `ingested_at` 改 ISO 8601 整鏈一致 |
| Week 起算日 | 🔴 不變（仍待確認） |
| ML rolling feature | 🔴 不變 |

### 14.10 成本與時間估算

實際資料量（new + legacy 兩個 bucket 合計）：~26 GiB / ~70K JSON 檔，flatten 後 bronze ~5 GiB / ~3,000–4,000 萬筆 row。

| 項目 | 估算 |
|---|---|
| Step 1 `bq load`（一次性，含 legacy） | ~10–30 分鐘，**$0**（load 本身免費） |
| Step 2 CTAS（UNNEST + UNION ALL + dedup） | ~1–3 分鐘，~26 GiB scan ≈ **$0.13** |
| Bronze observations 儲存（≈5 GiB） | **~$0.10/月** |
| Step 3 `DROP TABLE` staging | $0 |
| Daily load + MERGE | 每日 ~56 MiB scan ≈ **$0.0003/天** |
| **整體 bulk load + 第一個月** | **≈ $0.25** |

時間：本機跑 §14.2–14.5 全程 ~15–35 分鐘可結束。

### 14.11 Roll-forward 計畫（建議順序）

1. **本機跑 §14.2–14.5**：歷史 ~70K 檔載入 + 重組成 partitioned bronze（~30 分鐘）。
2. **§14.6 station metadata**：三張 dim 來源 bronze 一次性建立。
3. **Cloud Run Job 部署 daily load**（§14.7）：保證從明天起 bronze 不漏。
4. **dbt staging 用 §14.8 簡化版**：一張 view 對接 bronze。
5. **dbt 重建 int/fct**（沿用 §5–§6 設計）。
6. **dbt build 排程上線**（§13）：02:00 daily。
7. **觀測 1–2 週**：source freshness、daily load、dbt run 三項都穩。
8. **再考慮**：crawler 的 hive 命名 / ISO 8601 ingested_at 等優化（變成單純 nice-to-have）。

### 14.12 取捨清單

**接受**：
- Bronze 是 native table（多一張表、多一份儲存 ~6GB），但下游查詢不再依賴 GCS list。
- Bulk load 的 staging 表是中間產物（10 分鐘存在），習慣上要記得 `DROP TABLE`。
- bronze 的 `station_type` 由 SQL CASE 推導，下游 macro 變成「不需要重複計算」而不是「處處複製」。

**警覺**：
- BQ `--autodetect` 對 schema 演化的判斷不總是準確；如果 CWA 加新欄位，第一次 daily load 會失敗（schema mismatch）。對策：daily load 改 `--schema_update_option=ALLOW_FIELD_ADDITION` 或定期 review staging schema diff。
- 12 萬個小檔 GCS list 慢，未來資料量再翻倍時要考慮先合併小檔（`gsutil compose` 或 lifecycle policy）。
- bronze 沒做 incremental — 走 `MERGE` 邏輯，要保證 `(station_id, measure_at)` 真的 unique。crawler 偶爾雙寫（同一 timestamp 重抓兩次）會被 MERGE 收斂到最後一筆。

**不接受**：
- 不要走 `INSERT` 而非 `MERGE`（會產生重複）。
- 不要把 bronze 設成 `--time_partitioning_type=DAY` 的 ingestion-time partition（bulk load 全部會卡在同一天 partition，破壞 partition pruning）。
- 不要省略 step 3 的 DROP——staging 表是中間產物，留著只會產生混淆。

---

以上。歡迎針對任一節提出疑問或請我細化某段 SQL。
