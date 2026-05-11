resource "google_artifact_registry_repository" "dbt" {
  repository_id = var.ar_repo
  format        = "DOCKER"
  location      = var.region
  description   = "Holds dbt-weather and bronze-loader Cloud Run Job images."
}
