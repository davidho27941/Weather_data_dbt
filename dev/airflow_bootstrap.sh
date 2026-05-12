#!/usr/bin/env bash
#
# One-shot setup of a uv-managed venv for running the v2 DAGs locally.
# Idempotent: re-running upgrades pinned versions in place rather than
# rebuilding from scratch.
#
# Result:
#   .venv-airflow/                  ← uv venv with Airflow + providers + cosmos + dbt
#   .airflow-home/                  ← AIRFLOW_HOME (DB, logs, configs) — created on first `airflow standalone`
#
# Both paths are .gitignore'd.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

# --- Pinned versions ---------------------------------------------------------
# Airflow >= 2.9 is a hard requirement of cosmos 1.14 (watcher mode).
AIRFLOW_VERSION="${AIRFLOW_VERSION:-2.10.3}"
PYTHON_VERSION="${PYTHON_VERSION:-3.11}"

# Apache publishes a constraint file per (airflow, python) tuple. Without it,
# transitive deps fight each other and the install picks unstable versions.
CONSTRAINT_URL="https://raw.githubusercontent.com/apache/airflow/constraints-${AIRFLOW_VERSION}/constraints-${PYTHON_VERSION}.txt"

# --- venv --------------------------------------------------------------------
# Check for the python binary specifically, not just the directory — CI cache
# restores can land a partial shell (dir exists, binary missing) and a bare
# -d check would falsely report "reuse" and then `uv pip install` fails.
if [[ ! -x ".venv-airflow/bin/python" ]]; then
  if [[ -e ".venv-airflow" ]]; then
    echo "==> Found partial .venv-airflow without a python binary; removing"
    rm -rf .venv-airflow
  fi
  echo "==> Creating .venv-airflow (python ${PYTHON_VERSION})"
  uv venv .venv-airflow --python "${PYTHON_VERSION}"
else
  echo "==> Reusing existing .venv-airflow"
fi

# --- Airflow + providers (constrained) ---------------------------------------
echo "==> Installing Airflow ${AIRFLOW_VERSION} with constraints"
uv pip install --python .venv-airflow/bin/python \
  --constraint "${CONSTRAINT_URL}" \
  "apache-airflow==${AIRFLOW_VERSION}" \
  "apache-airflow-providers-google" \
  "apache-airflow-providers-http"

# --- Cosmos + dbt (unconstrained — cosmos pins its own deps) -----------------
# cosmos >= 1.14 for ExecutionMode.WATCHER.
# dbt-bigquery pinned to the same minor as the production dbt project
# (weather_data_dbt/package-lock.yml says 1.11.x).
echo "==> Installing cosmos + dbt"
uv pip install --python .venv-airflow/bin/python \
  "astronomer-cosmos>=1.14,<2.0" \
  "dbt-core>=1.11,<1.12" \
  "dbt-bigquery>=1.11,<1.12"

# --- openlineage cross-version fix ------------------------------------------
# Airflow 2.10's constraint file pins openlineage-python at ~1.34 but
# cosmos 1.14 brings in openlineage-integration-common ~1.47, which calls
# into facet_v2 symbols added in newer openlineage-python (e.g. `test_run`).
# Upgrade openlineage-python to match the integration-common minor so the
# imports line up. Run AFTER the cosmos install so we don't accidentally
# downgrade it again.
echo "==> Aligning openlineage-python with openlineage-integration-common"
uv pip install --python .venv-airflow/bin/python --upgrade \
  "openlineage-python>=1.47"

# --- Sanity check ------------------------------------------------------------
echo ""
echo "==> Versions installed:"
.venv-airflow/bin/python -c "
import importlib.metadata as m
for pkg in ['apache-airflow', 'apache-airflow-providers-google', 'apache-airflow-providers-http', 'astronomer-cosmos', 'dbt-core', 'dbt-bigquery']:
    try:
        print(f'  {pkg:45s} {m.version(pkg)}')
    except m.PackageNotFoundError:
        print(f'  {pkg:45s} (not installed)')
"

cat <<EOF

==> Bootstrap complete.

Next steps:

  # Check DAGs parse cleanly (fast, no Airflow processes):
  ./dev/airflow_check.sh

  # Or boot the full webserver + scheduler at http://localhost:8080:
  ./dev/airflow_run.sh
EOF
