#!/usr/bin/env bash
#
# Fast feedback loop: walks dags/ via Airflow's DagBag, reports import
# errors, lists discovered DAGs. No scheduler / webserver spun up.
#
# Run this after editing a DAG; if it's clean, the slower
# `./dev/airflow_run.sh` should also start cleanly.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

if [[ ! -x ".venv-airflow/bin/python" ]]; then
  echo "Error: .venv-airflow not found. Run ./dev/airflow_bootstrap.sh first." >&2
  exit 1
fi

# AIRFLOW_HOME stays inside the repo so the SQLite DB / logs / config
# don't pollute ~/airflow.
export AIRFLOW_HOME="${REPO_ROOT}/.airflow-home"
export AIRFLOW__CORE__LOAD_EXAMPLES="False"
export AIRFLOW__CORE__DAGS_FOLDER="${REPO_ROOT}/dags"

# Point cosmos at the local dbt + project so the DAG resolves correctly.
export DBT_PROJECT_PATH="${REPO_ROOT}/weather_data_dbt"
export DBT_PROJECT_DIR_LOCAL="${REPO_ROOT}/weather_data_dbt"
export DBT_EXECUTABLE_PATH="${REPO_ROOT}/.venv-airflow/bin/dbt"

# Cosmos writes a render-cache row into the Airflow Variable table on
# DAG parse — that needs the metadata DB schema to exist. `airflow db
# migrate` is idempotent; first run creates the SQLite file, subsequent
# runs no-op.
mkdir -p "${AIRFLOW_HOME}"
if [[ ! -f "${AIRFLOW_HOME}/airflow.db" ]]; then
  echo "==> Initialising Airflow metadata DB at ${AIRFLOW_HOME}/airflow.db"
  .venv-airflow/bin/airflow db migrate >/dev/null
fi

.venv-airflow/bin/python - <<'PY'
import os
import sys

from airflow.models import DagBag

dags_folder = os.environ["AIRFLOW__CORE__DAGS_FOLDER"]
bag = DagBag(dag_folder=dags_folder, include_examples=False)

print(f"DAGs folder: {dags_folder}\n")

if bag.import_errors:
    print("Import errors:")
    for path, err in bag.import_errors.items():
        print(f"  ✗ {path}")
        for line in str(err).splitlines():
            print(f"      {line}")
    sys.exit(1)

print(f"Loaded {len(bag.dags)} DAG(s):\n")
for dag_id, dag in sorted(bag.dags.items()):
    tag_str = ", ".join(sorted(dag.tags)) if dag.tags else "-"
    schedule = dag.schedule_interval or "-"
    print(f"  ✓ {dag_id}")
    print(f"      schedule: {schedule}")
    print(f"      tags:     {tag_str}")
    print(f"      tasks:    {len(dag.tasks)}")

print("\nAll DAGs parsed cleanly.")
PY
