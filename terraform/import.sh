#!/usr/bin/env bash
#
# Import all PR #3 / PR #4 GCP resources that were created via shell
# scripts into Terraform state, so the first `terraform plan` after this
# is (ideally) zero-diff.
#
# Each `terraform import` call is wrapped with `|| true` so re-running
# the script after one resource fails (or after partial state already
# exists) doesn't abort the rest.
#
# Run from terraform/ after `terraform init`:
#   cd terraform/
#   terraform init
#   ./import.sh
#   terraform plan
#
# Resources NOT imported here (intentional):
#   - GHA secrets / variables          (out of TF scope)
#   - SA keys for gha-ci / gha-cd      (security: keep keys out of tfstate)
#   - weather_raw dataset              (only IAM is TF-managed; dataset itself is bronze-owned)
#   - GCS bucket side-project-weather-data  (only IAM; bucket is crawler-owned)
#
set -euo pipefail

# --- inputs --------------------------------------------------------------

PROJECT="${GCP_PROJECT_ID:-side-project-staging}"
REGION="${BQ_LOCATION:-asia-east1}"
AR_REPO="${AR_REPO:-dbt}"
GCS_BUCKET="${GCS_BUCKET:-side-project-weather-data}"
ALERT_EMAIL="${ALERT_EMAIL:?Set ALERT_EMAIL=...@example.com (same address used to create the channel)}"

run_import() {
  local addr="$1"
  local id="$2"

  echo "==> import ${addr}"
  echo "    id=${id}"
  terraform import "${addr}" "${id}" || echo "    (skipped — already imported or doesn't exist)"
  echo
}

# --- service accounts ----------------------------------------------------

for SA in dbt-runner bronze-loader scheduler-invoker gha-ci gha-cd; do
  run_import \
    "google_service_account.sas[\"${SA}\"]" \
    "projects/${PROJECT}/serviceAccounts/${SA}@${PROJECT}.iam.gserviceaccount.com"
done

# --- artifact registry repo ----------------------------------------------

run_import \
  "google_artifact_registry_repository.dbt" \
  "projects/${PROJECT}/locations/${REGION}/repositories/${AR_REPO}"

# --- project-level IAM bindings ------------------------------------------
# google_project_iam_member ID format: "{project} {role} {member}"

declare -A PROJECT_BINDINGS=(
  ["dbt_runner_bq_user"]="roles/bigquery.user serviceAccount:dbt-runner@${PROJECT}.iam.gserviceaccount.com"
  ["bronze_loader_bq_user"]="roles/bigquery.user serviceAccount:bronze-loader@${PROJECT}.iam.gserviceaccount.com"
  ["gha_ci_bq_user"]="roles/bigquery.user serviceAccount:gha-ci@${PROJECT}.iam.gserviceaccount.com"
  ["gha_cd_run_developer"]="roles/run.developer serviceAccount:gha-cd@${PROJECT}.iam.gserviceaccount.com"
)
for KEY in "${!PROJECT_BINDINGS[@]}"; do
  run_import \
    "google_project_iam_member.project_bindings[\"${KEY}\"]" \
    "${PROJECT} ${PROJECT_BINDINGS[$KEY]}"
done

# --- AR repo IAM ---------------------------------------------------------

run_import \
  "google_artifact_registry_repository_iam_member.gha_cd_writer" \
  "projects/${PROJECT}/locations/${REGION}/repositories/${AR_REPO} roles/artifactregistry.writer serviceAccount:gha-cd@${PROJECT}.iam.gserviceaccount.com"

# --- GCS bucket IAM ------------------------------------------------------

run_import \
  "google_storage_bucket_iam_member.bronze_loader_bucket_viewer" \
  "b/${GCS_BUCKET} roles/storage.objectViewer serviceAccount:bronze-loader@${PROJECT}.iam.gserviceaccount.com"

# --- act-as bindings (gha-cd onto each runtime SA) -----------------------
# google_service_account_iam_member ID format:
#   "projects/{project}/serviceAccounts/{sa-email} {role} {member}"

for TARGET in dbt-runner bronze-loader; do
  run_import \
    "google_service_account_iam_member.gha_cd_act_as[\"${TARGET}\"]" \
    "projects/${PROJECT}/serviceAccounts/${TARGET}@${PROJECT}.iam.gserviceaccount.com roles/iam.serviceAccountUser serviceAccount:gha-cd@${PROJECT}.iam.gserviceaccount.com"
done

# --- BQ datasets ---------------------------------------------------------
# google_bigquery_dataset ID format: "projects/{project}/datasets/{name}"

for DS in weather_staging weather_intermediate weather_marts; do
  run_import \
    "google_bigquery_dataset.managed[\"${DS}\"]" \
    "projects/${PROJECT}/datasets/${DS}"
done

# --- BQ dataset-level IAM ------------------------------------------------
# google_bigquery_dataset_iam_member ID format:
#   "projects/{project}/datasets/{name} {role} {member}"

# dbt-runner editor on each managed dataset
for DS in weather_staging weather_intermediate weather_marts; do
  run_import \
    "google_bigquery_dataset_iam_member.dbt_runner_managed_editor[\"${DS}\"]" \
    "projects/${PROJECT}/datasets/${DS} roles/bigquery.dataEditor serviceAccount:dbt-runner@${PROJECT}.iam.gserviceaccount.com"
done

# dbt-runner viewer on weather_raw
run_import \
  "google_bigquery_dataset_iam_member.dbt_runner_raw_viewer" \
  "projects/${PROJECT}/datasets/weather_raw roles/bigquery.dataViewer serviceAccount:dbt-runner@${PROJECT}.iam.gserviceaccount.com"

# bronze-loader editor on weather_raw
run_import \
  "google_bigquery_dataset_iam_member.bronze_loader_raw_editor" \
  "projects/${PROJECT}/datasets/weather_raw roles/bigquery.dataEditor serviceAccount:bronze-loader@${PROJECT}.iam.gserviceaccount.com"

# gha-ci viewer on weather_raw
run_import \
  "google_bigquery_dataset_iam_member.gha_ci_raw_viewer" \
  "projects/${PROJECT}/datasets/weather_raw roles/bigquery.dataViewer serviceAccount:gha-ci@${PROJECT}.iam.gserviceaccount.com"

# --- Cloud Run Jobs ------------------------------------------------------
# google_cloud_run_v2_job ID format:
#   "projects/{project}/locations/{region}/jobs/{name}"

run_import \
  "google_cloud_run_v2_job.bronze_daily_load" \
  "projects/${PROJECT}/locations/${REGION}/jobs/bronze-daily-load"
run_import \
  "google_cloud_run_v2_job.dbt_weekly_build" \
  "projects/${PROJECT}/locations/${REGION}/jobs/dbt-weekly-build"
run_import \
  "google_cloud_run_v2_job.dbt_hourly_freshness" \
  "projects/${PROJECT}/locations/${REGION}/jobs/dbt-hourly-freshness"

# --- Cloud Run Job invoker IAM (for scheduler-invoker) -------------------
# google_cloud_run_v2_job_iam_member ID format:
#   "projects/{project}/locations/{region}/jobs/{name} {role} {member}"

for JOB in bronze-daily-load dbt-weekly-build dbt-hourly-freshness; do
  run_import \
    "google_cloud_run_v2_job_iam_member.scheduler_invoker[\"${JOB}\"]" \
    "projects/${PROJECT}/locations/${REGION}/jobs/${JOB} roles/run.invoker serviceAccount:scheduler-invoker@${PROJECT}.iam.gserviceaccount.com"
done

# --- Cloud Scheduler triggers --------------------------------------------
# google_cloud_scheduler_job ID format:
#   "projects/{project}/locations/{region}/jobs/{name}"

for JOB in bronze-daily-load dbt-weekly-build dbt-hourly-freshness; do
  run_import \
    "google_cloud_scheduler_job.triggers[\"${JOB}\"]" \
    "projects/${PROJECT}/locations/${REGION}/jobs/${JOB}-trigger"
done

# --- Monitoring channel + policy -----------------------------------------
# Look up by display label and policy id since their resource names are
# project-scoped numeric IDs, not stable identifiers.

CHANNEL_ID="$(
  gcloud alpha monitoring channels list \
    --project="${PROJECT}" \
    --filter="type=email AND labels.email_address=${ALERT_EMAIL}" \
    --format='value(name)' --limit=1 2>/dev/null
)"
if [ -n "${CHANNEL_ID}" ]; then
  run_import google_monitoring_notification_channel.email "${CHANNEL_ID}"
else
  echo "==> SKIP google_monitoring_notification_channel.email — no channel found for ${ALERT_EMAIL}"
fi

POLICY_ID="$(
  gcloud alpha monitoring policies list \
    --project="${PROJECT}" \
    --filter="user_labels.policy_id=cloud_run_job_failure" \
    --format='value(name)' --limit=1 2>/dev/null
)"
if [ -n "${POLICY_ID}" ]; then
  run_import google_monitoring_alert_policy.cloud_run_job_failure "${POLICY_ID}"
else
  echo "==> SKIP google_monitoring_alert_policy.cloud_run_job_failure — no policy found"
fi

cat <<EOF

Import pass complete.

Recommended next step:
  terraform plan

A clean import yields a near-zero plan. Anything actually changing means
the TF spec doesn't match what's deployed — adjust the .tf and re-plan
before any apply. Do NOT \`terraform apply\` until plan output is reviewed.
EOF
