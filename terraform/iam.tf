# ---------------------------------------------------------------------------
# Project-level role grants.
#
# Members are constructed as plain strings rather than `google_service_account.sas[X].email`
# references — `terraform import` evaluates dependent expressions per
# imported instance, and during early imports the SA collection only
# carries the one key being imported, so cross-key references error out.
# Hardcoding the email string sidesteps the issue without losing
# correctness (TF still creates SAs first via apply ordering).
# ---------------------------------------------------------------------------

locals {
  project_iam_bindings = {
    "dbt_runner_bq_user" = {
      role   = "roles/bigquery.user"
      member = "serviceAccount:dbt-runner@${var.project}.iam.gserviceaccount.com"
    }
    "bronze_loader_bq_user" = {
      role   = "roles/bigquery.user"
      member = "serviceAccount:bronze-loader@${var.project}.iam.gserviceaccount.com"
    }
    "gha_ci_bq_user" = {
      role   = "roles/bigquery.user"
      member = "serviceAccount:gha-ci@${var.project}.iam.gserviceaccount.com"
    }
    "gha_cd_run_developer" = {
      role   = "roles/run.developer"
      member = "serviceAccount:gha-cd@${var.project}.iam.gserviceaccount.com"
    }
  }
}

resource "google_project_iam_member" "project_bindings" {
  for_each = local.project_iam_bindings

  project = var.project
  role    = each.value.role
  member  = each.value.member
}

# ---------------------------------------------------------------------------
# Artifact Registry repo: gha-cd writes images here.
# ---------------------------------------------------------------------------

resource "google_artifact_registry_repository_iam_member" "gha_cd_writer" {
  project    = var.project
  location   = var.region
  repository = var.ar_repo
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:gha-cd@${var.project}.iam.gserviceaccount.com"
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
  member = "serviceAccount:bronze-loader@${var.project}.iam.gserviceaccount.com"
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

  service_account_id = "projects/${var.project}/serviceAccounts/${each.key}@${var.project}.iam.gserviceaccount.com"
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:gha-cd@${var.project}.iam.gserviceaccount.com"
}
