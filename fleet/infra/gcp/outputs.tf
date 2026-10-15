output "fleet_policy" { value = jsonencode(local.policy) }
output "controller" { value = google_compute_instance.trusted["controller"].name }
output "worker_service_account" { value = google_service_account.fleet["worker"].email }
output "gateway_service_account" { value = google_service_account.fleet["gateway"].email }
output "tls_secrets" { value = { for role, secret in google_secret_manager_secret.tls : role => secret.secret_id } }
output "github_identity_provider" { value = google_iam_workload_identity_pool_provider.github.name }
output "audit_bucket" { value = google_storage_bucket.audit.name }
