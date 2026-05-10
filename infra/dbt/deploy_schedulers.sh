#!/usr/bin/env bash
#
# Create or update the Cloud Scheduler triggers for the two dbt jobs:
#
#   dbt-weekly-build-trigger        cron '30 2 * * 1' Asia/Taipei  (Mon 02:30)
#                                 → POST .../jobs/dbt-weekly-build:run
#
#   dbt-hourly-freshness-trigger    cron '0 * * * *'  Asia/Taipei  (top of every hour)
#                                 → POST .../jobs/dbt-hourly-freshness:run
#
# The scheduler-invoker@ SA must already exist with roles/run.invoker on
# both Cloud Run Jobs — see .github/workflows/README.md §2c.
#
# Idempotent: each existing trigger is updated in place.
#
set -euo pipefail

PROJECT="${GCP_PROJECT_ID:-side-project-staging}"
REGION="${BQ_LOCATION:-asia-east1}"
SA_INVOKER="${SCHEDULER_INVOKER_SA:-scheduler-invoker@${PROJECT}.iam.gserviceaccount.com}"

deploy_trigger() {
  local job_name="$1"
  local schedule="$2"
  local label="$3"

  local trigger_name="${job_name}-trigger"
  local uri="https://${REGION}-run.googleapis.com/v2/projects/${PROJECT}/locations/${REGION}/jobs/${job_name}:run"

  local action
  if gcloud scheduler jobs describe "${trigger_name}" \
       --location="${REGION}" --project="${PROJECT}" >/dev/null 2>&1; then
    action="update"
  else
    action="create"
  fi

  echo "==> ${action} Cloud Scheduler trigger ${trigger_name}"
  echo "    schedule=${schedule} (Asia/Taipei) — ${label}"
  echo "    target=${job_name}"

  gcloud scheduler jobs "${action}" http "${trigger_name}" \
    --project="${PROJECT}" \
    --location="${REGION}" \
    --schedule="${schedule}" \
    --time-zone="Asia/Taipei" \
    --uri="${uri}" \
    --http-method=POST \
    --oauth-service-account-email="${SA_INVOKER}"

  echo
}

deploy_trigger "dbt-weekly-build"     "30 2 * * 1" "Monday 02:30 weekly batch"
deploy_trigger "dbt-hourly-freshness" "0 * * * *"  "every hour, source freshness"

cat <<EOF

Both dbt triggers ready.

Manual fire-now:
  gcloud scheduler jobs run dbt-weekly-build-trigger     --location=${REGION}
  gcloud scheduler jobs run dbt-hourly-freshness-trigger --location=${REGION}
EOF
