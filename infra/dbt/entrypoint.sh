#!/usr/bin/env bash
#
# dbt Cloud Run Job entrypoint.
#
# Forwards arguments to dbt with the configured target and profiles
# directory. Cloud Run Job CMD overrides `args` to choose what dbt
# subcommand to run (e.g. `build`, `source freshness`).
#
# Examples (from gcloud run jobs create / update):
#   --args="build"
#   --args="source,freshness"
#   --args="run,--select,fct_measurements_hourly+"
#
# Env vars consumed:
#   DBT_TARGET          dev / stg / prod (default stg, set in Dockerfile)
#   DBT_PROFILES_DIR    where profiles.yml lives (default in Dockerfile)
#   BRONZE_PROJECT      override the source `weather_raw` project
#   GCP_PROJECT_ID      consumed inside profiles.yml as DBT_*_PROJECT default
#
set -euo pipefail

echo "==> dbt entrypoint"
echo "    target=${DBT_TARGET}  profiles_dir=${DBT_PROFILES_DIR}"
echo "    bronze_project=${BRONZE_PROJECT:-(profile default)}"
echo "    args=$*"

exec dbt --no-use-colors "$@" --target "${DBT_TARGET}"
