#!/usr/bin/env bash
#
# Create or update the Cloud Scheduler trigger for the bronze daily MERGE.
#
#   bronze-daily-load-trigger    cron '0 2 * * *' Asia/Taipei
#                              → POST .../jobs/bronze-daily-load:run
#
# The scheduler-invoker@ SA must already exist with roles/run.invoker on
# the bronze-daily-load Cloud Run Job — see .github/workflows/README.md §2c.
#
# Idempotent: existing trigger is updated in place.
#
set -euo pipefail

PROJECT="${GCP_PROJECT_ID:-side-project-staging}"
REGION="${BQ_LOCATION:-asia-east1}"
SA_INVOKER="${SCHEDULER_INVOKER_SA:-scheduler-invoker@${PROJECT}.iam.gserviceaccount.com}"

JOB_NAME="bronze-daily-load"
TRIGGER_NAME="${JOB_NAME}-trigger"
SCHEDULE="0 2 * * *"            # daily 02:00
TIME_ZONE="Asia/Taipei"
URI="https://${REGION}-run.googleapis.com/v2/projects/${PROJECT}/locations/${REGION}/jobs/${JOB_NAME}:run"

if gcloud scheduler jobs describe "${TRIGGER_NAME}" \
     --location="${REGION}" --project="${PROJECT}" >/dev/null 2>&1; then
  ACTION="update"
else
  ACTION="create"
fi

echo "==> ${ACTION} Cloud Scheduler trigger ${TRIGGER_NAME}"
echo "    schedule=${SCHEDULE} (${TIME_ZONE})"
echo "    target=${JOB_NAME}"

gcloud scheduler jobs "${ACTION}" http "${TRIGGER_NAME}" \
  --project="${PROJECT}" \
  --location="${REGION}" \
  --schedule="${SCHEDULE}" \
  --time-zone="${TIME_ZONE}" \
  --uri="${URI}" \
  --http-method=POST \
  --oauth-service-account-email="${SA_INVOKER}"

echo
echo "Trigger ${TRIGGER_NAME} ready."
echo "Manual fire-now:"
echo "  gcloud scheduler jobs run ${TRIGGER_NAME} --location=${REGION}"
