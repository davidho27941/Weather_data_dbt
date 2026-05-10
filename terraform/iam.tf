# ---------------------------------------------------------------------------
# Project-level role grants.
#
# google_project_iam_member is per-(project, role, member) — additive, does
# not touch other principals on the same role. Safer than google_project_iam_binding
# (which would clobber everyone else holding that role).
# ---------------------------------------------------------------------------

locals {
  project_iam_bindings = {
    # dbt-runner: list datasets, create datasets the first dbt run needs,
    # run query jobs.
    "dbt_runner_bq_user" = {
      role   = "roles/bigquery.user"
      member = google_service_account.sas["dbt-runner"].email
    }
    # bronze-loader: same, but separate SA per least-priv.
    "bronze_loader_bq_user" = {
      role   = "roles/bigquery.user"
      member = google_service_account.sas["bronze-loader"].email
    }
    # gha-ci: lists weather_ci_* datasets, creates them if missing,
    # runs build queries.
    "gha_ci_bq_user" = {
      role   = "roles/bigquery.user"
      member = google_service_account.sas["gha-ci"].email
    }
    # gha-cd: roll Cloud Run Jobs onto new image tags.
    "gha_cd_run_developer" = {
      role   = "roles/run.developer"
      member = google_service_account.sas["gha-cd"].email
    }
  }
}

resource "google_project_iam_member" "project_bindings" {
  for_each = local.project_iam_bindings

  project = var.project
  role    = each.value.role
  member  = "serviceAccount:${each.value.member}"
}

# ---------------------------------------------------------------------------
# Artifact Registry repo: gha-cd writes images here.
# ---------------------------------------------------------------------------

resource "google_artifact_registry_repository_iam_member" "gha_cd_writer" {
  project    = var.project
  location   = google_artifact_registry_repository.dbt.location
  repository = google_artifact_registry_repository.dbt.name
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.sas["gha-cd"].email}"
}

# ---------------------------------------------------------------------------
# GCS bucket: bronze-loader reads crawler JSON.
#
# google_storage_bucket_iam_member targets a bucket that is NOT TF-managed
# here (it's owned by the crawler infra). The binding still lives in our
# state because we control the SA.
# ---------------------------------------------------------------------------

resource "google_storage_bucket_iam_member" "bronze_loader_bucket_viewer" {
  bucket = var.gcs_bucket
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.sas["bronze-loader"].email}"
}

# ---------------------------------------------------------------------------
# act-as: gha-cd needs roles/iam.serviceAccountUser on the two runtime
# SAs to deploy `gcloud run jobs update` against jobs that use them.
# ---------------------------------------------------------------------------

locals {
  cd_act_as_targets = ["dbt-runner", "bronze-loader"]
}

resource "google_service_account_iam_member" "gha_cd_act_as" {
  for_each = toset(local.cd_act_as_targets)

  service_account_id = google_service_account.sas[each.key].name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.sas["gha-cd"].email}"
}
