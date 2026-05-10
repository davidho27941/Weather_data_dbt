# ---------------------------------------------------------------------------
# Three pipeline Cloud Run Jobs.
#
# Image tag: each Job's image attribute is excluded from drift via
# lifecycle.ignore_changes, because the GHA dbt_cd.yml / bq_cd.yml
# workflows roll the running image forward on every main push. If TF
# tried to assert the image, every CD push would create perpetual drift.
#
# The image fields below use ":latest" as the placeholder Terraform sees
# during `terraform apply`. After import this attribute is preserved as
# whatever digest CD has rolled to most recently — the lifecycle block
# stops Terraform from touching it again.
# ---------------------------------------------------------------------------

# ----- Bronze daily MERGE --------------------------------------------------
resource "google_cloud_run_v2_job" "bronze_daily_load" {
  name     = "bronze-daily-load"
  location = var.region
  project  = var.project

  template {
    template {
      service_account = "bronze-loader@${var.project}.iam.gserviceaccount.com"
      max_retries     = 2
      timeout         = "900s"

      containers {
        image = "${local.image_repo}/bronze-loader:latest"

        resources {
          limits = {
            cpu    = "1"
            memory = "512Mi"
          }
        }

        env {
          name  = "GCP_PROJECT_ID"
          value = var.project
        }
        env {
          name  = "BQ_LOCATION"
          value = var.region
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      template[0].template[0].containers[0].image,
      client,
      client_version,
    ]
  }
}

# ----- dbt weekly build (Mon 02:30) ---------------------------------------
resource "google_cloud_run_v2_job" "dbt_weekly_build" {
  name     = "dbt-weekly-build"
  location = var.region
  project  = var.project

  template {
    template {
      service_account = "dbt-runner@${var.project}.iam.gserviceaccount.com"
      max_retries     = 1
      timeout         = "1800s"

      containers {
        image = "${local.image_repo}/dbt-weather:latest"
        args  = ["build"]

        resources {
          limits = {
            cpu    = "2"
            memory = "2Gi"
          }
        }

        env {
          name  = "DBT_TARGET"
          value = "stg"
        }
        env {
          name  = "GCP_PROJECT_ID"
          value = var.project
        }
        env {
          name  = "BRONZE_PROJECT"
          value = var.project
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      template[0].template[0].containers[0].image,
      client,
      client_version,
    ]
  }
}

# ----- dbt source freshness (hourly) --------------------------------------
resource "google_cloud_run_v2_job" "dbt_hourly_freshness" {
  name     = "dbt-hourly-freshness"
  location = var.region
  project  = var.project

  template {
    template {
      service_account = "dbt-runner@${var.project}.iam.gserviceaccount.com"
      max_retries     = 1
      timeout         = "1800s"

      containers {
        image = "${local.image_repo}/dbt-weather:latest"
        args  = ["source", "freshness"]

        resources {
          limits = {
            cpu    = "2"
            memory = "2Gi"
          }
        }

        env {
          name  = "DBT_TARGET"
          value = "stg"
        }
        env {
          name  = "GCP_PROJECT_ID"
          value = var.project
        }
        env {
          name  = "BRONZE_PROJECT"
          value = var.project
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      template[0].template[0].containers[0].image,
      client,
      client_version,
    ]
  }
}

