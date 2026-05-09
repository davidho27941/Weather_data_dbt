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

FROM ghcr.io/dbt-labs/dbt-bigquery:1.8.latest

# dbt-bigquery image runs as root by default; that's fine for Cloud Run Jobs.
WORKDIR /workspace

# Copy project + profile in
COPY weather_data_dbt/ ./weather_data_dbt/

# Install package dependencies into the image.
WORKDIR /workspace/weather_data_dbt
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
