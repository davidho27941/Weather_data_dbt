# ---------------------------------------------------------------------------
# Cloud Scheduler triggers — one per Cloud Run Job.
#
# Each trigger HTTP-POSTs to the Job's :run endpoint, OAuth-authenticated
# as scheduler-invoker@. The invoker SA must hold roles/run.invoker on
# each Job (declared below).
# ---------------------------------------------------------------------------

resource "google_cloud_scheduler_job" "triggers" {
  for_each = toset(local.cloud_run_jobs)

  project   = var.project
  region    = var.region
  name      = "${each.key}-trigger"
  schedule  = var.schedules[each.key]
  time_zone = "Asia/Taipei"

  http_target {
    http_method = "POST"
    uri         = "https://${var.region}-run.googleapis.com/v2/projects/${var.project}/locations/${var.region}/jobs/${each.key}:run"

    oauth_token {
      service_account_email = "scheduler-invoker@${var.project}.iam.gserviceaccount.com"
    }
  }

  # Declare retry_config explicitly with the API defaults — otherwise the
  # provider returns the defaulted block on every refresh and TF wants
  # to remove it, producing an eternal in-place drift loop. retry_count=0
  # means no Scheduler-level retry; the Cloud Run Job itself has its own
  # max_retries set per Job.
  retry_config {
    retry_count          = 0
    min_backoff_duration = "5s"
    max_backoff_duration = "3600s"
    max_doublings        = 5
    max_retry_duration   = "0s"
  }

  # The Cloud Run Job must exist before the trigger references its :run URI.
  depends_on = [
    google_cloud_run_v2_job.bronze_daily_load,
    google_cloud_run_v2_job.dbt_weekly_build,
    google_cloud_run_v2_job.dbt_hourly_freshness,
  ]
}

# ---------------------------------------------------------------------------
# scheduler-invoker SA needs roles/run.invoker on each Job to actually
# trigger them via :run.
# ---------------------------------------------------------------------------

resource "google_cloud_run_v2_job_iam_member" "scheduler_invoker" {
  for_each = toset(local.cloud_run_jobs)

  project  = var.project
  location = var.region
  name     = each.key
  role     = "roles/run.invoker"
  member   = "serviceAccount:scheduler-invoker@${var.project}.iam.gserviceaccount.com"

  depends_on = [
    google_cloud_run_v2_job.bronze_daily_load,
    google_cloud_run_v2_job.dbt_weekly_build,
    google_cloud_run_v2_job.dbt_hourly_freshness,
  ]
}
