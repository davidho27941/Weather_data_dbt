# dbt-bigquery image for Cloud Run Jobs.
#
# Builds a self-contained image with the project + dependencies. The Cloud
# Run Job entrypoint runs `dbt build` (or `dbt source freshness`) against
# the target specified by the DBT_TARGET env var (stg / prod).
#
# Build:
#   docker build -t dbt-weather:$TAG -f infra/dbt/Dockerfile .
#
# Push to Artifact Registry:
#   docker tag dbt-weather:$TAG $REGION-docker.pkg.dev/$PROJECT/dbt/dbt-weather:$TAG
#   docker push $REGION-docker.pkg.dev/$PROJECT/dbt/dbt-weather:$TAG

# dbt installed via pip rather than via a pre-built dbt-labs image:
#   - pinned to the same 1.11.x as the local uv venv + GHA CI (the
#     committed package-lock.yml is 1.11-shaped)
#   - mirrors the install path the dbt_ci.yml / build_dbt_docs.yml
#     workflows use, so behavior is identical between CI and Cloud Run
#   - ghcr.io/dbt-labs/dbt-bigquery's tagging is inconsistent and several
#     `1.x.latest` tags 403 on anonymous pull
FROM python:3.11-slim

RUN pip install --no-cache-dir \
      'dbt-core>=1.11,<1.12' \
      'dbt-bigquery>=1.11,<1.12'

WORKDIR /workspace

# Copy project in
COPY weather_data_dbt/ ./weather_data_dbt/

WORKDIR /workspace/weather_data_dbt

# profiles/profiles.yml is gitignored (each dev's local file); the image
# materializes it from the committed example template at build time. The
# example uses env_var() throughout and contains no secrets — every project /
# dataset / location is overridable via Cloud Run Job env vars.
RUN cp profiles/profiles.example.yml profiles/profiles.yml

# Install package dependencies (dbt_utils) into the image.
RUN dbt deps \
    --profiles-dir /workspace/weather_data_dbt/profiles

# Default env vars (override per-job via Cloud Run Job env config):
#   DBT_TARGET           which profile target to run (dev / stg / prod)
#   GCP_PROJECT_ID       BQ project (consumed inside profiles.yml)
#   BRONZE_PROJECT       bronze layer project (consumed by sources.yml)
ENV DBT_PROFILES_DIR=/workspace/weather_data_dbt/profiles
ENV DBT_TARGET=stg

# entrypoint.sh receives the dbt subcommand to run.
COPY infra/dbt/entrypoint.sh /usr/local/bin/dbt-entrypoint
RUN chmod +x /usr/local/bin/dbt-entrypoint

ENTRYPOINT ["dbt-entrypoint"]
CMD ["build"]
