# ---------------------------------------------------------------------------
# Log-based metric: counts dbt test failures emitted by the weekly build
# and hourly freshness Jobs.
#
# When a dbt test with severity=error fails, dbt prints a log line like:
#
#   3 of 25 FAIL 12 not_null_fct_measurements_10min_station_id ...
#                                              [FAIL 12 in 0.32s]
#
# Severity=warn tests print a similar line with "WARN" instead. This
# metric matches only the error case — the warn case (relationships and
# anomaly checks) is intentionally observed-only and stays out of the
# critical alert path.
#
# Rationale for splitting this off from the generic cloud_run_job_failure
# alert: that alert fires on ANY non-zero Job exit (OOM, network error,
# auth, SQL error, test error — all bundled together). This metric
# narrows the signal to "specifically a data-quality assertion broke",
# which is a different on-call response.
# ---------------------------------------------------------------------------

resource "google_logging_metric" "dbt_test_failure" {
  project = var.project
  name    = "dbt_test_failure_count"

  description = "dbt severity=error test failures from the weekly build / hourly freshness Cloud Run Jobs."

  filter = <<-EOT
    resource.type="cloud_run_job"
    resource.labels.job_name=("dbt-weekly-build" OR "dbt-hourly-freshness")
    (textPayload=~"FAIL [0-9]+ " OR jsonPayload.message=~"FAIL [0-9]+ ")
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

# ---------------------------------------------------------------------------
# Alert policy on the log-based metric above.
#
# Triggers as soon as the metric reports >= 1 failure in a 5-minute
# window. Uses the existing email channel; auto-closes after 24h.
# ---------------------------------------------------------------------------

resource "google_monitoring_alert_policy" "dbt_test_failure" {
  project      = var.project
  display_name = "dbt test — assertion failed"
  combiner     = "OR"

  user_labels = {
    policy_id  = "dbt_test_failure"
    managed_by = "terraform"
  }

  documentation {
    mime_type = "text/markdown"
    content   = <<-EOT
      One or more dbt tests with severity=error failed in the most recent
      pipeline run. Unlike the generic Cloud Run Job failure alert, this
      isolates data-quality assertion breaks from infra / runtime errors.

      Investigate:
        gcloud logging read 'resource.type="cloud_run_job"
          AND resource.labels.job_name=("dbt-weekly-build" OR "dbt-hourly-freshness")
          AND textPayload=~"FAIL "' \
          --limit=20 --format='value(timestamp,textPayload)' --freshness=1d

      Look at the dbt build summary, then re-run targeted with:
        dbt test --select <failed_test_name> --target stg
    EOT
  }

  conditions {
    display_name = "logging/user/dbt_test_failure_count > 0"

    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.dbt_test_failure.name}\" AND resource.type=\"cloud_run_job\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_SUM"
      }

      trigger {
        count = 1
      }
    }
  }

  notification_channels = [
    google_monitoring_notification_channel.email.name,
  ]

  alert_strategy {
    auto_close = "86400s"
  }
}

# ---------------------------------------------------------------------------
# Pipeline-health dashboard.
#
# Single dashboard, four panels in a 2x2 grid:
#   1. Cloud Run Job execution count (success vs. failed), per job
#   2. dbt test failures from the log-based metric above
#   3. BigQuery slot utilisation
#   4. Crawler bucket storage bytes, broken out by storage class so we
#      can watch the lifecycle tiering work
#
# Dashboard JSON is non-trivial; we build it via jsonencode() so it
# diffs nicely in PRs rather than as one opaque string.
# ---------------------------------------------------------------------------

locals {
  dbt_test_failure_metric_type = "logging.googleapis.com/user/${google_logging_metric.dbt_test_failure.name}"

  pipeline_health_dashboard = {
    displayName = "Weather pipeline health"
    gridLayout = {
      columns = "2"
      widgets = [
        {
          title = "Cloud Run Job — completed executions (by result)"
          xyChart = {
            chartOptions = { mode = "COLOR" }
            dataSets = [{
              plotType   = "STACKED_BAR"
              targetAxis = "Y1"
              timeSeriesQuery = {
                timeSeriesFilter = {
                  filter = "metric.type=\"run.googleapis.com/job/completed_execution_count\" resource.type=\"cloud_run_job\" resource.label.job_name=monitoring.regex.full_match(\"bronze-daily-load|dbt-weekly-build|dbt-hourly-freshness\")"
                  aggregation = {
                    alignmentPeriod    = "3600s"
                    perSeriesAligner   = "ALIGN_SUM"
                    crossSeriesReducer = "REDUCE_SUM"
                    groupByFields = [
                      "resource.label.job_name",
                      "metric.label.result",
                    ]
                  }
                }
              }
            }]
            timeshiftDuration = "0s"
          }
        },

        {
          title = "dbt test failures (severity=error)"
          xyChart = {
            chartOptions = { mode = "COLOR" }
            dataSets = [{
              plotType   = "LINE"
              targetAxis = "Y1"
              timeSeriesQuery = {
                timeSeriesFilter = {
                  filter = "metric.type=\"${local.dbt_test_failure_metric_type}\" resource.type=\"cloud_run_job\""
                  aggregation = {
                    alignmentPeriod    = "3600s"
                    perSeriesAligner   = "ALIGN_SUM"
                    crossSeriesReducer = "REDUCE_SUM"
                    groupByFields      = ["resource.label.job_name"]
                  }
                }
              }
            }]
            timeshiftDuration = "0s"
          }
        },

        {
          title = "BigQuery — slots in use"
          xyChart = {
            chartOptions = { mode = "COLOR" }
            dataSets = [{
              plotType   = "LINE"
              targetAxis = "Y1"
              timeSeriesQuery = {
                timeSeriesFilter = {
                  filter = "metric.type=\"bigquery.googleapis.com/slots/total_used\" resource.type=\"bigquery_project\""
                  aggregation = {
                    alignmentPeriod    = "300s"
                    perSeriesAligner   = "ALIGN_MEAN"
                    crossSeriesReducer = "REDUCE_MEAN"
                  }
                }
              }
            }]
            timeshiftDuration = "0s"
          }
        },

        {
          title = "Crawler bucket — bytes by storage class"
          xyChart = {
            chartOptions = { mode = "COLOR" }
            dataSets = [{
              plotType   = "LINE"
              targetAxis = "Y1"
              timeSeriesQuery = {
                timeSeriesFilter = {
                  filter = "metric.type=\"storage.googleapis.com/storage/total_bytes\" resource.type=\"gcs_bucket\" resource.label.bucket_name=\"${var.gcs_bucket}\""
                  aggregation = {
                    alignmentPeriod    = "3600s"
                    perSeriesAligner   = "ALIGN_MEAN"
                    crossSeriesReducer = "REDUCE_MEAN"
                    groupByFields      = ["metric.label.storage_class"]
                  }
                }
              }
            }]
            timeshiftDuration = "0s"
          }
        },
      ]
    }
  }
}

resource "google_monitoring_dashboard" "pipeline_health" {
  project        = var.project
  dashboard_json = jsonencode(local.pipeline_health_dashboard)
}
