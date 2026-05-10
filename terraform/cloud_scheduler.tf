# ---------------------------------------------------------------------------
# Cloud Scheduler triggers — one per Cloud Run Job.
#
# Each trigger HTTP-POSTs to the Job's :run endpoint, OAuth-authenticated
# as scheduler-invoker@. The invoker SA must hold roles/run.invoker on
# each Job (declared below).
# ---------------------------------------------------------------------------

resource "google_cloud_scheduler_job" "triggers" {
  for_each = local.cloud_run_job_resources

  project   = var.project
  region    = var.region
  name      = "${each.key}-trigger"
  schedule  = var.schedules[each.key]
  time_zone = "Asia/Taipei"

  http_target {
    http_method = "POST"
    uri         = "https://${var.region}-run.googleapis.com/v2/projects/${var.project}/locations/${var.region}/jobs/${each.key}:run"

    oauth_token {
      service_account_email = google_service_account.sas["scheduler-invoker"].email
    }
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
  for_each = local.cloud_run_job_resources

  project  = var.project
  location = var.region
  name     = each.value.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.sas["scheduler-invoker"].email}"
}
