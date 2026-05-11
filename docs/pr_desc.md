# GCS lifecycle: import crawler bucket + tiered archival

## Summary

Brings the crawler GCS bucket (`side-project-weather-data`) under
Terraform management and adds a tiered storage-class lifecycle so
crawler JSON ages into cheaper tiers automatically:

```
Standard       0 – 30 days     active ingestion + bronze MERGE lookback
Nearline      30 – 90 days     rare access
Coldline      90 – 365 days    archival
Archive       365+ days        forever (no delete action)
```

State-class minimums (Nearline 30d, Coldline 90d, Archive 365d) are all
satisfied by the gaps between transitions — no early-deletion fees.

PR #5 left the bucket out of TF scope ("crawler-owned"). That was an
asymmetry: the IAM binding on the bucket was already TF-managed but the
bucket itself wasn't. Bringing it in closes that gap so the GCS
lifecycle is versioned in code, reviewable, and drift-detectable.

## Why no `Delete` action

Crawler JSON is the raw input to every bronze backfill we could ever
want to run. Archive class is ~$0.0012/GB/month — for the crawler's
~KB-per-file volume the long-tail cost is rounding-error, and the
optionality of "we can always re-derive bronze from source" is worth
more than the saved storage cost. If we ever decide to cap retention,
add a 4th `lifecycle_rule` with `action.type = "Delete"`; nothing about
the current schedule blocks that.

## Why bucket goes under TF (not lifecycle-only)

GCS doesn't expose lifecycle as a separate resource — it's a nested
block on `google_storage_bucket`. So managing lifecycle in TF requires
managing the bucket. The alternatives — leaving lifecycle out of TF and
using `gcloud storage buckets update --lifecycle-file=...` — would
break the source-of-truth principle PR #5 established, and reintroduce
shell-script drift.

## Blast-radius protection

`lifecycle { prevent_destroy = true }` on the bucket resource. The
bucket holds every raw payload the pipeline has ever ingested; an
accidental `terraform destroy` (or a config edit that removed the
resource block) would otherwise drop it all. With the flag set, TF
refuses the destroy until the flag is explicitly flipped to `false` in
a dedicated commit. Removal-on-purpose is therefore a two-commit
operation.

## Import is a no-op for data and config

`terraform plan` after import yields:

```
Plan: 0 to add, 1 to change, 0 to destroy.

  # google_storage_bucket.crawler will be updated in-place
  ~ resource "google_storage_bucket" "crawler" {
      ~ terraform_labels = { + "goog-terraform-provisioned" = "true" }
      + lifecycle_rule { ... STANDARD → NEARLINE @ 30d  }
      + lifecycle_rule { ... NEARLINE → COLDLINE @ 90d  }
      + lifecycle_rule { ... COLDLINE → ARCHIVE  @ 365d }
    }
```

- No object data is touched.
- The `terraform_labels` line is a TF-state-only update: the
  `goog-terraform-provisioned=true` label was already on the bucket
  (set by some prior tool); apply just records that TF now manages it.
- The three new lifecycle rules begin governing object aging from the
  apply forward; objects already older than the thresholds will
  transition in the next nightly GCS sweep, no manual action required.

## Changes

| File | Change |
|---|---|
| [`terraform/storage.tf`](terraform/storage.tf) | New: `google_storage_bucket.crawler` with three `lifecycle_rule` blocks and `prevent_destroy = true` |
| [`terraform/import.sh`](terraform/import.sh) | Added `terraform import google_storage_bucket.crawler ${PROJECT}/${GCS_BUCKET}`; removed the bucket from the "NOT imported" comment block |
| [`terraform/README.md`](terraform/README.md) | Crawler bucket row added to the managed-resources table, removed from "Out of scope"; new section explaining `prevent_destroy` |
| [`README.md`](README.md) + [`multilingual_readme/readme_jp.md`](multilingual_readme/readme_jp.md) | Repository layout + Future work updated |

## Test plan

- [x] `terraform init` — clean.
- [x] `terraform import google_storage_bucket.crawler "${PROJECT}/${GCS_BUCKET}"` — successful.
- [x] `terraform plan` — exactly `Plan: 0 to add, 1 to change, 0 to destroy`
      with only the three lifecycle_rule additions + the cosmetic
      `terraform_labels` row in the diff. No recreation, no destroy.
- [ ] `terraform plan -out=tfplan && terraform apply tfplan`.
- [ ] `terraform plan` again — should print `No changes`.
- [ ] `gcloud storage buckets describe gs://side-project-weather-data --format='value(lifecycle)'`
      shows the three rules.
- [ ] (Optional, after enough wall-clock time has passed) Spot-check
      `gsutil ls -L gs://side-project-weather-data/dt=2025-12-* | grep "Storage class"`
      shows objects transitioning to NEARLINE / COLDLINE as the age
      thresholds fire.

## Out of scope

- `Delete` action — see "Why no Delete action" above.
- Object versioning — not enabled today; not enabled by this PR.
- CMEK / per-object retention — not required for crawler data sensitivity.
- The dbt-managed `weather_*` datasets and the `weather_raw` dataset are
  unchanged by this PR.

## References

- Future work item this PR closes:
  [`README.md` § Future work](../README.md#future-work) →
  "GCS lifecycle policy on the crawler bucket"
- Bucket settings observed pre-import:
  `gcloud storage buckets describe gs://side-project-weather-data`
  (ASIA-EAST1, STANDARD default class, UBLA off, 7-day soft delete).
- Branch: `feat/gcs-lifecycle` → `main`
