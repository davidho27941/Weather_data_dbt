locals {
  cloud_run_jobs = ["bronze-daily-load", "dbt-weekly-build", "dbt-hourly-freshness"]

  # The three "production" stg datasets dbt writes to. weather_dev_* and
  # weather_ci_* are intentionally NOT managed here — they are dev /
  # ephemeral and dbt creates them as needed via project-level
  # bigquery.user.
  managed_datasets = [
    "weather_staging",
    "weather_intermediate",
    "weather_marts",
  ]

  # Pre-existing bronze dataset; only IAM is TF-managed, the dataset
  # itself is owned by the bronze layer's bulk-load run history.
  bronze_dataset = "weather_raw"

  # Image repo path used by the Cloud Run Jobs. Tag is intentionally not
  # set here — the GHA CD workflow rolls images forward, and the Job's
  # image attribute is excluded from drift via lifecycle.ignore_changes.
  image_repo = "${var.region}-docker.pkg.dev/${var.project}/${var.ar_repo}"
}
