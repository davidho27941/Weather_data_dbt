# ---------------------------------------------------------------------------
# Crawler GCS bucket.
#
# Pre-existing — created out-of-band when the crawler service was first
# stood up. Imported into TF in this PR so we can manage the lifecycle
# policy in code (tier crawler JSON to Nearline / Coldline / Archive as
# it ages, then keep it in Archive indefinitely).
#
# `prevent_destroy = true` is load-bearing here: this bucket holds every
# raw crawler payload ever ingested. A stray `terraform destroy` (or a
# config edit that removes this resource block) would otherwise wipe the
# whole bronze source-of-truth. To intentionally remove the bucket, flip
# the flag to false in a dedicated commit, then destroy.
# ---------------------------------------------------------------------------

resource "google_storage_bucket" "crawler" {
  name     = var.gcs_bucket
  project  = var.project
  location = "ASIA-EAST1"

  storage_class               = "STANDARD"
  uniform_bucket_level_access = false
  public_access_prevention    = "inherited"

  # Matches the current bucket state (7-day soft delete, GCP default
  # since 2024). Declared explicitly so future provider-default changes
  # don't show up as drift.
  soft_delete_policy {
    retention_duration_seconds = 604800
  }

  # Tiering schedule. Aging conditions key off object create-time, so
  # `age = 30` on a STANDARD object fires 30 days after the crawler
  # wrote it. `matches_storage_class` scopes each rule to the source
  # tier so transitions chain cleanly without double-firing.
  #
  # Minimum storage durations (Nearline 30d, Coldline 90d, Archive 365d)
  # are all satisfied by the gaps between transitions — no early-deletion
  # fees.
  lifecycle_rule {
    condition {
      age                   = 30
      matches_storage_class = ["STANDARD"]
    }
    action {
      type          = "SetStorageClass"
      storage_class = "NEARLINE"
    }
  }

  lifecycle_rule {
    condition {
      age                   = 90
      matches_storage_class = ["NEARLINE"]
    }
    action {
      type          = "SetStorageClass"
      storage_class = "COLDLINE"
    }
  }

  lifecycle_rule {
    condition {
      age                   = 365
      matches_storage_class = ["COLDLINE"]
    }
    action {
      type          = "SetStorageClass"
      storage_class = "ARCHIVE"
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}
