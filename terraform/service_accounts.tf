locals {
  service_accounts = {
    "dbt-runner" = {
      display_name = "dbt Cloud Run Job runtime"
      description  = "Runtime SA for dbt-weekly-build and dbt-hourly-freshness Cloud Run Jobs."
    }
    "bronze-loader" = {
      display_name = "bronze daily-load Cloud Run Job runtime"
      description  = "Runtime SA for bronze-daily-load Cloud Run Job. Reads GCS, writes weather_raw."
    }
    "scheduler-invoker" = {
      display_name = "Cloud Scheduler → Cloud Run Job invoker"
      description  = "OAuth identity Cloud Scheduler triggers use to call the three pipeline jobs."
    }
    "gha-ci" = {
      display_name = "GitHub Actions dbt CI"
      description  = "Runs dbt parse / build / docs against weather_ci_* datasets from PRs."
    }
    "gha-cd" = {
      display_name = "GitHub Actions CD (dbt + bronze)"
      description  = "Pushes images to Artifact Registry and rolls Cloud Run Jobs onto new image tags."
    }
  }
}

resource "google_service_account" "sas" {
  for_each = local.service_accounts

  account_id   = each.key
  display_name = each.value.display_name
  description  = each.value.description
}
