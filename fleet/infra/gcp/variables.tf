variable "project_id" { type = string }
variable "region" {
  type    = string
  default = "us-central1"
}
variable "zones" {
  type    = list(string)
  default = ["us-central1-a", "us-central1-b"]
}
variable "prefix" {
  type    = string
  default = "sim-fleet"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,17}$", var.prefix))
    error_message = "Use a short lowercase resource prefix."
  }
}
variable "release_digest" {
  type = string
  validation {
    condition     = can(regex("^[a-f0-9]{64}$", var.release_digest))
    error_message = "The verified release digest is required."
  }
}
variable "worker_host_image" {
  type = string
  validation {
    condition     = can(regex("^projects/[^/]+/global/images/[^/]+$", var.worker_host_image))
    error_message = "Use an immutable GCP image name, never an image family."
  }
}
variable "trusted_host_image" {
  type = string
  validation {
    condition     = can(regex("^projects/[^/]+/global/images/[^/]+$", var.trusted_host_image))
    error_message = "Use an immutable GCP image name, never an image family."
  }
}
variable "worker_container_image" {
  type = string
  validation {
    condition     = can(regex("@sha256:[a-f0-9]{64}$", var.worker_container_image))
    error_message = "Pin the worker OCI image by digest."
  }
}
variable "sandbox_template" {
  type = string
  validation {
    condition     = can(regex("@sha256:[a-f0-9]{64}$", var.sandbox_template))
    error_message = "Pin the sbx template by digest."
  }
}
variable "hardware_public_key" {
  type = string
  validation {
    condition     = can(regex("^sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh.com ", var.hardware_public_key))
    error_message = "Use your OpenSSH FIDO public key."
  }
}
variable "admin_subjects" { type = list(string) }
variable "admin_members" {
  type        = list(string)
  description = "Explicit owner IAM members, such as user:you@example.com."
}
variable "admin_audience" {
  type        = string
  description = "Audience of your gcloud user's Google ID token; this is a public client identifier."
}
variable "ca_certificate_pem" {
  type        = string
  description = "Public fleet CA certificate only. Never supply a private key to Terraform."
}
variable "codex_models" { type = list(string) }
variable "claude_models" { type = list(string) }
variable "openai_provider_id" {
  type    = string
  default = ""
}
variable "openai_service_account_id" {
  type    = string
  default = ""
}
variable "github_repository_id" {
  type        = string
  description = "Numeric GitHub repository ID allowed to request deployment identity."
}
variable "github_owner_id" { type = string }
variable "github_workflow_ref" {
  type        = string
  description = "Exact protected job_workflow_ref; no wildcard."
}
variable "max_hosts" {
  type    = number
  default = 10
}
variable "max_agents" {
  type    = number
  default = 200
}
variable "host_hourly_micros" {
  type        = number
  description = "Dated regional compute estimate in USD micros per host-hour."
}
variable "max_fleet_micros" {
  type        = number
  description = "Maximum concurrently authorized compute estimate in USD micros."
}
variable "audit_retention_seconds" {
  type    = number
  default = 2592000
}

variable "egress_hosts" {
  type = list(string)
  description = "Reviewed exact public HTTPS repository authorities. New hosts require a new policy and signed grant."
  default = ["deb.debian.org:443", "security.debian.org:443", "registry.npmjs.org:443", "pypi.org:443", "files.pythonhosted.org:443", "index.crates.io:443", "static.crates.io:443"]
}
variable "max_task_egress_bytes" {
  type = number
  default = 2147483648
}
