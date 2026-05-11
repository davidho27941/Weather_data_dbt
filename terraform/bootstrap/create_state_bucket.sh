#!/usr/bin/env bash
#
# One-time bootstrap: create the GCS bucket Terraform will use as its
# remote state backend. Idempotent — succeeds quickly if the bucket
# already exists.
#
# Run this once before the first `terraform init`.
#
set -euo pipefail

PROJECT="${GCP_PROJECT_ID:-side-project-staging}"
REGION="${BQ_LOCATION:-asia-east1}"
BUCKET="${TFSTATE_BUCKET:-weather-pipeline-tfstate}"

if gcloud storage buckets describe "gs://${BUCKET}" --project="${PROJECT}" >/dev/null 2>&1; then
  echo "Bucket gs://${BUCKET} already exists — nothing to do."
  exit 0
fi

echo "==> Creating gs://${BUCKET} in ${REGION} (${PROJECT})"

gcloud storage buckets create "gs://${BUCKET}" \
  --project="${PROJECT}" \
  --location="${REGION}" \
  --uniform-bucket-level-access \
  --public-access-prevention

# Versioning is non-negotiable for tfstate buckets — every apply mutates
# the state, and a corrupted apply needs to be rolled back to a previous
# generation rather than restored from backup.
gcloud storage buckets update "gs://${BUCKET}" \
  --project="${PROJECT}" \
  --versioning

# Soft-delete retention default is 7 days, sometimes longer. For homelab
# scope we keep the default; tighten/loosen via Console if needed.

cat <<EOF

State bucket gs://${BUCKET} ready.

Next steps:
  cd terraform/
  terraform init
  ./import.sh
  terraform plan
EOF
