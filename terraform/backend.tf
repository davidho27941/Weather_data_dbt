# Remote state lives in a GCS bucket so successive `terraform apply` runs
# from different workstations / CI all see the same state. Bootstrap the
# bucket once via terraform/bootstrap/create_state_bucket.sh before the
# first `terraform init`.
terraform {
  backend "gcs" {
    bucket = "weather-pipeline-tfstate"
    prefix = "weather-pipeline"
  }
}
