#!/usr/bin/env bash
#
# Thin wrapper around daily_load.sql for ad-hoc / backfill execution.
#
# In production this SQL is meant to run as a BigQuery Scheduled Query
# (see daily_load.sql header comment for deployment notes). This shell
# wrapper exists for:
#
#   - Local sanity testing before deploying the scheduled query.
#   - Manual backfills:  YESTERDAY=2026-05-08 ./daily_load.sh
#   - One-off CI / cron-style invocation if you prefer that over BQ schedules.
#
# Usage:
#   ./daily_load.sh                # loads yesterday in Asia/Taipei (SQL default)
#   YESTERDAY=2026-05-08 ./daily_load.sh    # loads a specific day
#
set -euo pipefail

PROJECT="${GCP_PROJECT_ID:-side-project-weather}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_FILE="${SCRIPT_DIR}/daily_load.sql"

# Empty parameter triggers the SQL's default (yesterday in Asia/Taipei).
TARGET_DATE="${YESTERDAY:-}"

if [ -n "${TARGET_DATE}" ]; then
  echo "Daily load — target_date=${TARGET_DATE} (override)"
else
  echo "Daily load — target_date defaults to yesterday in Asia/Taipei"
fi

bq query \
  --project_id="${PROJECT}" \
  --use_legacy_sql=false \
  --max_rows=0 \
  --parameter="target_date:STRING:${TARGET_DATE}" \
  < "${SQL_FILE}"

echo "Daily load complete."
