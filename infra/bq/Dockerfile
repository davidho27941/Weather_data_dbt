# bronze-daily-load image for the Cloud Run Job that runs daily_load.sql.
#
# Thin container: the existing infra/bq/daily_load.sh already wraps the SQL
# with bq CLI invocation and a target_date parameter; the Cloud Run Job
# just needs an image with the gcloud SDK + that script + the SQL.
#
# Build:
#   docker build -t bronze-loader:$TAG -f infra/bq/Dockerfile infra/bq/
#
# Push to Artifact Registry (reuses the existing `dbt` repo to avoid a
# separate AR repo + IAM grant for one extra image):
#   docker tag bronze-loader:$TAG \
#     $REGION-docker.pkg.dev/$PROJECT/dbt/bronze-loader:$TAG
#   docker push $REGION-docker.pkg.dev/$PROJECT/dbt/bronze-loader:$TAG

FROM gcr.io/google.com/cloudsdktool/cloud-sdk:slim

WORKDIR /workspace

COPY daily_load.sql daily_load.sh ./
RUN chmod +x daily_load.sh

# Defaults consumed by daily_load.sh; both can be overridden per-environment
# via Cloud Run Job env config. BQ_LOCATION matters because bq CLI defaults
# to US otherwise — `weather_raw` is in asia-east1.
ENV GCP_PROJECT_ID=side-project-staging
ENV BQ_LOCATION=asia-east1

ENTRYPOINT ["/workspace/daily_load.sh"]
