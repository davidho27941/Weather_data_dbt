#!/usr/bin/env bash
#
# Idempotently sets up Cloud Monitoring email alerts for the pipeline
# Cloud Run Jobs:
#
#   1. Ensures an email notification channel for ${ALERT_EMAIL} exists.
#   2. Renders alert_policies/*.yaml with that channel ID and either
#      creates or updates the corresponding alert policy.
#
# Usage:
#   ALERT_EMAIL=davidho.prime@gmail.com ./deploy.sh
#
# Re-running is safe: existing channels / policies are reused or updated
# in place, never duplicated.
#
# Each policy YAML must declare `userLabels.policy_id: <id>`; the deploy
# script uses that label to find an existing policy on update (rather
# than parsing displayName, which trips on non-ASCII chars under macOS
# BSD sed).
#
set -euo pipefail

PROJECT="${GCP_PROJECT_ID:-side-project-staging}"
ALERT_EMAIL="${ALERT_EMAIL:?Set ALERT_EMAIL=...@example.com to choose the recipient}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICIES_DIR="${SCRIPT_DIR}/alert_policies"

CHANNEL_DISPLAY_NAME="pipeline-alerts (${ALERT_EMAIL})"

# ---------------------------------------------------------------------------
# 0. Pre-install gcloud `alpha` components quietly. If we leave this for
#    the first `gcloud alpha monitoring ...` call, gcloud auto-installs
#    interactively and its installer output ends up captured by command
#    substitution — contaminating ${NOTIFICATION_CHANNEL_ID} and breaking
#    the rendered YAML.
# ---------------------------------------------------------------------------
gcloud components install alpha --quiet >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# 1. Ensure the email notification channel exists.
# ---------------------------------------------------------------------------
echo "==> Ensuring email notification channel for ${ALERT_EMAIL}"

NOTIFICATION_CHANNEL_ID="$(
  gcloud alpha monitoring channels list \
    --project="${PROJECT}" \
    --filter="type=email AND labels.email_address=${ALERT_EMAIL}" \
    --format="value(name)" \
    --limit=1 \
    2>/dev/null
)"

if [ -z "${NOTIFICATION_CHANNEL_ID}" ]; then
  echo "    creating new channel..."
  NOTIFICATION_CHANNEL_ID="$(
    gcloud alpha monitoring channels create \
      --project="${PROJECT}" \
      --display-name="${CHANNEL_DISPLAY_NAME}" \
      --type=email \
      --channel-labels="email_address=${ALERT_EMAIL}" \
      --format="value(name)" \
      2>/dev/null
  )"
  echo "    created: ${NOTIFICATION_CHANNEL_ID}"
else
  echo "    reusing existing: ${NOTIFICATION_CHANNEL_ID}"
fi

export NOTIFICATION_CHANNEL_ID
export GCP_PROJECT_ID="${PROJECT}"

# ---------------------------------------------------------------------------
# 2. Render and apply each alert policy under alert_policies/.
# ---------------------------------------------------------------------------
for policy_template in "${POLICIES_DIR}"/*.yaml; do
  policy_id="$(basename "${policy_template}" .yaml)"

  echo
  echo "==> Applying alert policy: ${policy_id}"

  # Render envsubst-substituted YAML to a temp file.
  rendered="$(mktemp)"
  envsubst < "${policy_template}" > "${rendered}"

  # Lookup by user_labels.policy_id (set inside each YAML). This is more
  # robust than parsing displayName — userLabels is a structured field.
  existing_id="$(
    gcloud alpha monitoring policies list \
      --project="${PROJECT}" \
      --filter="user_labels.policy_id=${policy_id}" \
      --format="value(name)" \
      --limit=1 \
      2>/dev/null
  )"

  if [ -z "${existing_id}" ]; then
    echo "    creating..."
    gcloud alpha monitoring policies create \
      --project="${PROJECT}" \
      --policy-from-file="${rendered}"
  else
    echo "    updating ${existing_id}..."
    gcloud alpha monitoring policies update "${existing_id}" \
      --project="${PROJECT}" \
      --policy-from-file="${rendered}"
  fi

  rm -f "${rendered}"
done

cat <<EOF

Alert wiring complete.

Verify in Console:
  https://console.cloud.google.com/monitoring/alerting/policies?project=${PROJECT}

Quick smoke test — force a Job failure and watch the email arrive
(execute a Job with a bogus arg so it exits non-zero):
  gcloud run jobs execute dbt-hourly-freshness \\
    --region=asia-east1 \\
    --args=source,freshness,--bogus-flag

(Don't forget to confirm the email subscription on first send — Cloud
Monitoring sends a one-time verification email before any alerts.)
EOF
