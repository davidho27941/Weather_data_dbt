output "service_account_emails" {
  description = "Email addresses of the five managed SAs."
  value       = { for k, sa in google_service_account.sas : k => sa.email }
}

output "cloud_run_job_names" {
  description = "Names of the three pipeline Cloud Run Jobs."
  value       = [for j in local.cloud_run_job_resources : j.name]
}

output "scheduler_trigger_names" {
  description = "Names of the three Cloud Scheduler triggers."
  value       = [for t in google_cloud_scheduler_job.triggers : t.name]
}

output "notification_channel_id" {
  description = "Resource name of the email notification channel."
  value       = google_monitoring_notification_channel.email.name
}

output "alert_policy_id" {
  description = "Resource name of the cloud-run-job-failure alert policy."
  value       = google_monitoring_alert_policy.cloud_run_job_failure.name
}
