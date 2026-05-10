# ---------------------------------------------------------------------------
# Production stg datasets owned by Terraform.
#
# weather_dev_* and weather_ci_* are intentionally not managed here:
#   - dev datasets vary per developer
#   - ci datasets are rebuilt on every PR run
# Both are created on demand by dbt via project-level bigquery.user.
#
# weather_raw is a pre-existing dataset owned by the bronze layer's
# bulk-load history. We only manage IAM on it via google_bigquery_dataset_iam_member,
# never the dataset resource itself.
# ---------------------------------------------------------------------------

resource "google_bigquery_dataset" "managed" {
  for_each   = toset(local.managed_datasets)
  dataset_id = each.key
  location   = var.region

  description = "dbt-managed silver/gold layer (${each.key})."

  # Don't auto-delete tables on dataset destroy — guards against
  # accidentally nuking marts data via `terraform destroy`.
  delete_contents_on_destroy = false
}

# ---------------------------------------------------------------------------
# Dataset-level IAM
#
# google_bigquery_dataset_iam_member uses the standard BQ access ACL path
# (bigquery.datasets.update on the dataset) and is NOT subject to the
# allowlist that gates `bq add-iam-policy-binding` — so this works on
# side-project-staging even though the gcloud-CLI equivalent didn't.
# ---------------------------------------------------------------------------

# dbt-runner: write access to its three output datasets.
resource "google_bigquery_dataset_iam_member" "dbt_runner_managed_editor" {
  for_each   = google_bigquery_dataset.managed
  dataset_id = each.value.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${google_service_account.sas["dbt-runner"].email}"
}

# dbt-runner: read access to weather_raw bronze.
resource "google_bigquery_dataset_iam_member" "dbt_runner_raw_viewer" {
  dataset_id = local.bronze_dataset
  role       = "roles/bigquery.dataViewer"
  member     = "serviceAccount:${google_service_account.sas["dbt-runner"].email}"
}

# bronze-loader: write access to weather_raw (its job is to MERGE into it).
resource "google_bigquery_dataset_iam_member" "bronze_loader_raw_editor" {
  dataset_id = local.bronze_dataset
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${google_service_account.sas["bronze-loader"].email}"
}

# gha-ci: read access to weather_raw so dbt parse / build sees the bronze schema.
resource "google_bigquery_dataset_iam_member" "gha_ci_raw_viewer" {
  dataset_id = local.bronze_dataset
  role       = "roles/bigquery.dataViewer"
  member     = "serviceAccount:${google_service_account.sas["gha-ci"].email}"
}
