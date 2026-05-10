# ---------------------------------------------------------------------------
# Email notification channel.
#
# After import, the channel keeps its existing verificationStatus
# (VERIFIED). On a fresh apply (e.g. for a new env / new email), Cloud
# Monitoring sends a verification email and the channel stays UNVERIFIED
# until the recipient runs the :verify REST call with the code from the
# email — see infra/monitoring/README.md.
# ---------------------------------------------------------------------------

resource "google_monitoring_notification_channel" "email" {
  project      = var.project
  display_name = "pipeline-alerts (${var.alert_email})"
  type         = "email"

  labels = {
    email_address = var.alert_email
  }

  user_labels = {
    managed_by = "terraform"
  }

  # Verification status is set out-of-band by clicking the email's code
  # back into the Monitoring API. Don't let TF assert it.
  lifecycle {
    ignore_changes = [
      verification_status,
    ]
  }
}

# ---------------------------------------------------------------------------
# Alert policy: any of the three pipeline Cloud Run Jobs finishes a
# retry-exhausted execution with result=failed.
# ---------------------------------------------------------------------------

resource "google_monitoring_alert_policy" "cloud_run_job_failure" {
  project      = var.project
  display_name = "Cloud Run Job — execution failed"
  combiner     = "OR"

  user_labels = {
    policy_id  = "cloud_run_job_failure"
    managed_by = "terraform"
  }

  documentation {
    mime_type = "text/markdown"
    content   = <<-EOT
      A pipeline Cloud Run Job (bronze-daily-load / dbt-weekly-build /
      dbt-hourly-freshness) finished with result=failed after exhausting
      retries.

      Investigate:
        gcloud run jobs executions list --job=<job-name> --region=asia-east1 --limit=5
        gcloud beta run jobs executions describe <execution-name> --region=asia-east1
    EOT
  }

  conditions {
    display_name = "completed_execution_count{result=failed} > 0"

    condition_threshold {
      filter = <<-EOT
        metric.type="run.googleapis.com/job/completed_execution_count"
        AND resource.type="cloud_run_job"
        AND metric.label.result="failed"
        AND resource.label.job_name=monitoring.regex.full_match("bronze-daily-load|dbt-weekly-build|dbt-hourly-freshness")
      EOT

      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_SUM"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields      = ["resource.label.job_name"]
      }

      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"

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
