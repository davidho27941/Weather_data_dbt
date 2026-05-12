#!/usr/bin/env bash
#
# Boot Airflow locally for interactive validation. Uses `airflow
# standalone` which runs scheduler + webserver + SQLite metadata DB in
# a single foreground process; the admin password is printed to stdout
# on first run and persists in .airflow-home/standalone_admin_password.txt.
#
# Web UI:    http://localhost:8080
# User:      admin
# Password:  cat .airflow-home/standalone_admin_password.txt

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

if [[ ! -x ".venv-airflow/bin/python" ]]; then
  echo "Error: .venv-airflow not found. Run ./dev/airflow_bootstrap.sh first." >&2
  exit 1
fi

export AIRFLOW_HOME="${REPO_ROOT}/.airflow-home"
export AIRFLOW__CORE__LOAD_EXAMPLES="False"
export AIRFLOW__CORE__DAGS_FOLDER="${REPO_ROOT}/dags"

# Scheduler-side defaults so the UI doesn't dump a wall of timezone
# warnings on every page load.
export AIRFLOW__CORE__DEFAULT_TIMEZONE="Asia/Taipei"

# Reroute DAG paths to local checkout. Production defaults in the DAG
# files point at /opt/airflow/...; local validation paths are the repo
# checkout plus the bootstrapped dbt venv.
export DBT_PROJECT_PATH="${REPO_ROOT}/weather_data_dbt"
export DBT_PROJECT_DIR_LOCAL="${REPO_ROOT}/weather_data_dbt"
export DBT_EXECUTABLE_PATH="${REPO_ROOT}/.venv-airflow/bin/dbt"

# Some providers (Google in particular) refuse to load without a default
# project; set a dummy if the real env doesn't have one. The DAGs read
# their own GCS bucket / GCP project via Airflow Variables, so this only
# affects connection initialization.
export GOOGLE_CLOUD_PROJECT="${GOOGLE_CLOUD_PROJECT:-side-project-staging}"

mkdir -p "${AIRFLOW_HOME}"

echo "==> AIRFLOW_HOME=${AIRFLOW_HOME}"
echo "==> Web UI will be at http://localhost:8080 (admin / see standalone_admin_password.txt)"
echo

exec .venv-airflow/bin/airflow standalone
