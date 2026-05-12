# dbt docs: publish catalog stats against `stg` target (PR #9)

## Summary

Until now, the dbt-docs site on GitHub Pages showed row counts and
table sizes from `weather_ci_*` — the datasets PR-CI rebuilds with a
7-day bronze subsample. That made the published catalog misleading
(e.g. `fct_measurements_10min` showing ~319k rows when the prod table
in `weather_marts` has the full historical millions).

This PR switches `build_dbt_docs.yml` to compile against `--target stg`
so the catalog reflects the prod marts. To make that work, `gha-ci`
needs read access on the three stg-managed datasets — provisioned in
Terraform.

## Root cause recap

| Component | Target | Writes to | Volume |
|---|---|---|---|
| `dbt_ci.yml` (PR validation) | `ci` + `--vars '{ci_sample_days: 7}'` | `weather_ci_*` | ~319k rows (7-day sample) |
| `build_dbt_docs.yml` (was) | `ci` | (read-only) | inherits the 319k sample |
| `dbt-weekly-build` (prod) | `stg` | `weather_{staging,intermediate,marts}` | full history (Ms of rows) |

`dbt docs generate` doesn't build anything; it queries
INFORMATION_SCHEMA on the target's resolved datasets. So whichever
target the workflow uses determines which physical tables the catalog
introspects. Until this PR, that target was the wrong one.

## Changes

### `terraform/bigquery.tf`

Adds three `google_bigquery_dataset_iam_member` resources granting
`gha-ci` the `bigquery.dataViewer` role on each of
`weather_{staging,intermediate,marts}`. Read-only — `gha-ci` does not
get editor or owner; it cannot mutate prod data.

```hcl
resource "google_bigquery_dataset_iam_member" "gha_ci_managed_viewer" {
  for_each   = toset(local.managed_datasets)
  dataset_id = each.key
  role       = "roles/bigquery.dataViewer"
  member     = "serviceAccount:gha-ci@${var.project}.iam.gserviceaccount.com"
  depends_on = [google_bigquery_dataset.managed]
}
```

### `.github/workflows/build_dbt_docs.yml`

Single substantive change: `--target ci` → `--target stg`. Header
comment and the "Required IAM" note also updated so the next reader
doesn't have to re-derive the design.

### `dbt deps` / build steps

No change — `dbt docs generate` only needs the manifest + a connection
that can read INFORMATION_SCHEMA on the target datasets. No models are
materialised by this workflow.

## Why not switch the workflow's auth to gha-cd (which already has
broader access)?

Considered, rejected. Two reasons:

- `gha-cd` has `roles/run.developer` and writer access to Artifact
  Registry. A docs-publishing job doesn't need either, and giving a
  workflow more than it needs is a small but real security regression.
- The minimal grant (`bigquery.dataViewer` on three specific datasets)
  is tighter than "use the CD SA" and creates no precedent for "docs
  jobs should use CD credentials".

## Test plan

- [x] `terraform validate` — passes.
- [x] `terraform plan` — `3 to add, 1 to change, 0 to destroy`.
      The 3 adds are the new `gha_ci_managed_viewer` IAM bindings.
      The 1 in-place change is the BQ dashboard panel converging on
      the `scanned_bytes_billed` filter that was specified in PR #7
      commit `724c6c4` but never `terraform apply`d to live state
      after PR #7 merged — this PR's apply incidentally fixes that
      drift.
- [ ] `terraform apply` on this branch's plan after merge.
- [ ] Watch `build_dbt_docs.yml` run on the merge commit, confirm:
      - Auth step succeeds with the same `GCP_SA_KEY_CI` secret.
      - `dbt docs generate --target stg` step succeeds (no
        permission-denied errors on `weather_*` datasets).
      - Published GitHub Pages site shows `fct_measurements_10min`
        row count consistent with the live BQ table (compare against
        `bq query 'SELECT COUNT(*) FROM weather_marts.fct_measurements_10min'`).

## Out of scope

- **Removing `weather_ci_*` from the catalog entirely.** The CI
  datasets still exist and are still useful for ad-hoc inspection
  during PR review. They just shouldn't be what the published docs
  reflect.
- **Auto-refresh on weekly build.** Docs only regenerate on push to
  `main` touching `weather_data_dbt/**`. After this PR, row counts
  shown still lag by one weekly dbt-build run. That's acceptable —
  schema and lineage are what readers come for; row counts are
  illustrative. A workflow trigger on dbt-weekly-build completion is
  Future work (not currently warranted).

## References

- Reporting issue that triggered this: row-count mismatch between
  dbt docs and BQ console.
- Branch: `feat/dbt-docs-stg-target` → `main`
