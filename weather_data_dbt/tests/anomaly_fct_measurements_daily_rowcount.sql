{{ config(severity='warn') }}

{#
    Row-count anomaly detection — daily grain
    -----------------------------------------

    Compares the latest day's row count in fct_measurements_daily against
    the trailing 30-day baseline (excluding the latest day from the
    baseline so it can't pull the mean toward itself). Fails if the
    deviation exceeds 3 standard deviations.

    Catches silent failures that range / referential tests can't:

      - Partial crawler outage (some stations down → row count drops)
      - Parser bug dropping records (row count drops)
      - Duplicate / double-MERGE backfill (row count doubles)
      - Schema change in upstream CWA payload reducing parseable rows

    severity = warn (NOT error):

      Anomalies are not always bugs — typhoon days can legitimately spike
      observation density for some columns, prolonged outages can
      depress counts. We want the signal to appear in dbt test output
      and Cloud Monitoring (via the log-based metric) for human
      review, but not to fail the weekly build.

    Limits (be honest about them at interview time):

      - Needs ~14 days of history before std stabilises; first
        rebuild / new project will under-flag.
      - Catches sharp jumps, not slow drift — slow drift is absorbed
        into the moving baseline.
      - 3σ assumes roughly-normal distribution. Daily row counts have
        weekday/weekend structure and seasonality; for tighter signal
        the next iteration would be MAD (median absolute deviation)
        or a 7-day weekday-aware baseline. Z-score chosen here for
        explainability and zero dependencies.
#}

with daily_counts as (
    select
        timestamp_trunc(measure_at, day) as day_at,
        count(*) as row_count
    from {{ ref('fct_measurements_daily') }}
    where measure_at >= timestamp_sub(current_timestamp(), interval 31 day)
    group by 1
),

baseline as (
    -- Exclude the latest day so it can't bias its own threshold.
    select
        avg(row_count)    as mean_count,
        stddev(row_count) as std_count,
        count(*)          as baseline_days
    from daily_counts
    where day_at < (select max(day_at) from daily_counts)
),

latest as (
    select day_at, row_count
    from daily_counts
    where day_at = (select max(day_at) from daily_counts)
)

select
    l.day_at,
    l.row_count,
    b.mean_count,
    b.std_count,
    b.baseline_days,
    safe_divide(abs(l.row_count - b.mean_count), b.std_count) as z_score
from latest l
cross join baseline b
where b.baseline_days >= 14                              -- skip until baseline is stable
  and b.std_count > 0                                    -- avoid div-by-zero on flat series
  and abs(l.row_count - b.mean_count) > 3 * b.std_count  -- 3-sigma threshold
