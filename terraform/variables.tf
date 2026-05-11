variable "project" {
  description = "GCP project ID hosting the pipeline (currently the staging project)"
  type        = string
  default     = "side-project-staging"
}

variable "region" {
  description = "GCP region used for BQ, Cloud Run Jobs, Cloud Scheduler, and Artifact Registry"
  type        = string
  default     = "asia-east1"
}

variable "ar_repo" {
  description = "Artifact Registry repo holding the dbt-weather and bronze-loader images"
  type        = string
  default     = "dbt"
}

variable "gcs_bucket" {
  description = "GCS bucket the crawler writes to and the bronze loader reads from"
  type        = string
  default     = "side-project-weather-data"
}

variable "alert_email" {
  description = "Email address for Cloud Monitoring alert notifications"
  type        = string
}

# ---------------------------------------------------------------------------
# Cron schedules (Asia/Taipei) — kept as a variable so weekend changes don't
# need a code edit, just a tfvars override.
# ---------------------------------------------------------------------------
variable "schedules" {
  description = "Cloud Scheduler cron expressions per Cloud Run Job, Asia/Taipei"
  type        = map(string)
  default = {
    bronze-daily-load    = "0 2 * * *"
    dbt-weekly-build     = "30 2 * * 1"
    dbt-hourly-freshness = "0 * * * *"
  }
}
