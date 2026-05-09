#!/usr/bin/env bash
#
# Build the dbt-weather Docker image and push to Artifact Registry.
#
# Usage:
#   ./build_and_push.sh [TAG]
#
# Defaults:
#   TAG          $(git rev-parse --short HEAD) at the time of run
#   PROJECT      side-project-staging
#   REGION       asia-east1
#   AR_REPO      dbt
#
set -euo pipefail

TAG="${1:-$(git rev-parse --short HEAD 2>/dev/null || echo latest)}"
PROJECT="${GCP_PROJECT_ID:-side-project-staging}"
REGION="${BQ_LOCATION:-asia-east1}"
AR_REPO="${AR_REPO:-dbt}"

IMAGE="${REGION}-docker.pkg.dev/${PROJECT}/${AR_REPO}/dbt-weather:${TAG}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "==> Building ${IMAGE}"
echo "    repo root: ${REPO_ROOT}"

docker build \
  -t "${IMAGE}" \
  -f "${SCRIPT_DIR}/Dockerfile" \
  "${REPO_ROOT}"

echo "==> Pushing ${IMAGE}"
docker push "${IMAGE}"

echo
echo "Image pushed: ${IMAGE}"
echo
echo "To update the Cloud Run Jobs to use this image, run:"
echo "  gcloud run jobs update dbt-daily-build       --region=${REGION} --image=${IMAGE}"
echo "  gcloud run jobs update dbt-hourly-freshness  --region=${REGION} --image=${IMAGE}"
