#!/usr/bin/env bash
#
# Build the bronze-loader Docker image and push to Artifact Registry.
#
# Usage:
#   ./build_and_push.sh [TAG]
#
# Defaults:
#   TAG          $(git rev-parse --short HEAD) at the time of run
#   PROJECT      side-project-staging
#   REGION       asia-east1
#   AR_REPO      dbt        (reused — same repo as the dbt Cloud Run Job images)
#
set -euo pipefail

TAG="${1:-$(git rev-parse --short HEAD 2>/dev/null || echo latest)}"
PROJECT="${GCP_PROJECT_ID:-side-project-staging}"
REGION="${BQ_LOCATION:-asia-east1}"
AR_REPO="${AR_REPO:-dbt}"

IMAGE="${REGION}-docker.pkg.dev/${PROJECT}/${AR_REPO}/bronze-loader:${TAG}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Building ${IMAGE}"
echo "    context: ${SCRIPT_DIR}"

docker build \
  --platform=linux/amd64 \
  -t "${IMAGE}" \
  -f "${SCRIPT_DIR}/Dockerfile" \
  "${SCRIPT_DIR}"

echo "==> Pushing ${IMAGE}"
docker push "${IMAGE}"

echo
echo "Image pushed: ${IMAGE}"
echo
echo "To update the Cloud Run Job to use this image, run:"
echo "  gcloud run jobs update bronze-daily-load --region=${REGION} --image=${IMAGE}"
