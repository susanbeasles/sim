locals {
  roles         = toset(["controller", "worker", "gateway", "collector", "reaper", "deployer"])
  trusted_roles = toset(["controller", "gateway", "collector", "reaper"])
  template_name = "${var.prefix}-workers-${substr(var.release_digest, 0, 12)}"
  addresses     = { controller = "10.20.0.2", gateway = "10.20.0.3", collector = "10.20.0.4", reaper = "10.20.0.5" }
  audience      = "https://${var.prefix}.invalid/fleet"
  policy = {
    schema = 1, fleet = var.prefix, project = var.project_id, region = var.region, zones = var.zones
    controllerURL = "https://${local.addresses.controller}:7660", gatewayURL = "https://${local.addresses.gateway}:7661"
    audience = local.audience, adminAudience = var.admin_audience, adminSubjects = var.admin_subjects
    workerSubject = google_service_account.fleet["worker"].unique_id, gatewaySubject = google_service_account.fleet["gateway"].unique_id
    template = "projects/${var.project_id}/global/instanceTemplates/${local.template_name}"
    releaseDigest = var.release_digest, hardwarePublicKey = var.hardware_public_key
    workerImage = var.worker_container_image, sandboxTemplate = var.sandbox_template
    maxHosts = var.max_hosts, maxAgents = var.max_agents, maxGrantSeconds = 14400
    hostCPUs = 32, hostMemoryMiB = 131072, reserveMemoryMiB = 28672, cpuOvercommit = 2
    idleSeconds = 600, leaseSeconds = 90, maxArtifactBytes = 67108864, maxLogBytes = 8388608
    hostHourlyMicros = var.host_hourly_micros, maxFleetMicros = var.max_fleet_micros
    egressHosts = var.egress_hosts, maxTaskEgressBytes = var.max_task_egress_bytes
    models = { codex = var.codex_models, claude = var.claude_models }
    profiles = {
      light    = { cpus = 1, memoryMiB = 2048, diskMiB = 10240, maxSeconds = 3600 }
      standard = { cpus = 2, memoryMiB = 4096, diskMiB = 20480, maxSeconds = 7200 }
      heavy    = { cpus = 4, memoryMiB = 8192, diskMiB = 40960, maxSeconds = 14400 }
    }
  }
  common_service = { policy = "/etc/sim-fleet/policy.json", ca = "/etc/sim-fleet/ca.crt", state = "/var/lib/sim-fleet" }
}

resource "google_project_service" "api" {
  for_each = toset(["compute.googleapis.com", "iam.googleapis.com", "iamcredentials.googleapis.com", "sts.googleapis.com", "iap.googleapis.com", "oslogin.googleapis.com", "storage.googleapis.com", "secretmanager.googleapis.com", "aiplatform.googleapis.com"])
  service            = each.value
  disable_on_destroy = false
}

resource "google_service_account" "fleet" {
  for_each     = local.roles
  account_id   = "${var.prefix}-${each.key}"
  display_name = "SIM ${each.key}"
  depends_on   = [google_project_service.api]
}

resource "google_compute_network" "fleet" {
  name                    = var.prefix
  auto_create_subnetworks = false
  depends_on              = [google_project_service.api]
}
resource "google_compute_subnetwork" "fleet" {
  name                     = var.prefix
  region                   = var.region
  network                  = google_compute_network.fleet.id
  ip_cidr_range            = "10.20.0.0/24"
  private_ip_google_access = true
}
resource "google_compute_router" "fleet" {
  name    = var.prefix
  region  = var.region
  network = google_compute_network.fleet.id
}
resource "google_compute_router_nat" "fleet" {
  name                               = var.prefix
  router                             = google_compute_router.fleet.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"
  min_ports_per_vm                   = 2048
  subnetwork {
    name                    = google_compute_subnetwork.fleet.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }
  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}
resource "google_compute_firewall" "iap" {
  name          = "${var.prefix}-iap"
  network       = google_compute_network.fleet.name
  source_ranges = ["35.235.240.0/20"]
  target_tags   = [var.prefix]
  allow {
    protocol = "tcp"
    ports = ["22"]
  }
}
resource "google_compute_firewall" "controller" {
  name          = "${var.prefix}-controller"
  network       = google_compute_network.fleet.name
  source_tags   = ["${var.prefix}-worker", "${var.prefix}-gateway"]
  target_tags   = ["${var.prefix}-controller"]
  allow {
    protocol = "tcp"
    ports = ["7660"]
  }
}
resource "google_compute_firewall" "gateway" {
  name          = "${var.prefix}-gateway"
  network       = google_compute_network.fleet.name
  source_tags   = ["${var.prefix}-worker"]
  target_tags   = ["${var.prefix}-gateway"]
  allow {
    protocol = "tcp"
    ports = ["7661"]
  }
}
resource "google_compute_firewall" "collector" {
  name          = "${var.prefix}-collector"
  network       = google_compute_network.fleet.name
  source_tags   = ["${var.prefix}-controller"]
  target_tags   = ["${var.prefix}-collector"]
  allow {
    protocol = "tcp"
    ports = ["7662"]
  }
}
resource "google_compute_firewall" "egress_private" {
  name               = "${var.prefix}-private-egress"
  network            = google_compute_network.fleet.name
  direction          = "EGRESS"
  priority           = 1000
  destination_ranges = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
  target_tags        = [var.prefix]
  deny { protocol = "all" }
}
resource "google_compute_firewall" "egress_services" {
  name               = "${var.prefix}-services-egress"
  network            = google_compute_network.fleet.name
  direction          = "EGRESS"
  priority           = 900
  destination_ranges = ["10.20.0.2/32", "10.20.0.3/32", "10.20.0.4/32"]
  target_tags        = [var.prefix]
  allow {
    protocol = "tcp"
    ports = ["7660", "7661", "7662"]
  }
}

resource "google_storage_bucket" "audit" {
  name                        = "${var.project_id}-${var.prefix}-audit"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false
  retention_policy { retention_period = var.audit_retention_seconds }
  versioning { enabled = true }
}
resource "google_storage_bucket_iam_member" "collector" {
  bucket = google_storage_bucket.audit.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.fleet["collector"].email}"
}
resource "google_storage_bucket_iam_member" "owner_audit" {
  for_each = toset(var.admin_members)
  bucket   = google_storage_bucket.audit.name
  role     = "roles/storage.objectViewer"
  member   = each.value
}

resource "google_project_iam_custom_role" "controller" {
  role_id     = "${replace(var.prefix, "-", "_")}_controller"
  title       = "SIM bounded host provisioning"
  permissions = ["compute.instances.create", "compute.instances.delete", "compute.instances.get", "compute.instances.list", "compute.instances.setLabels", "compute.instances.setServiceAccount", "compute.instances.setMetadata", "compute.instances.setTags", "compute.instanceTemplates.get", "compute.instanceTemplates.useReadOnly", "compute.disks.create", "compute.disks.use", "compute.images.useReadOnly", "compute.subnetworks.use", "compute.zoneOperations.get", "compute.regionOperations.get", "compute.globalOperations.get"]
}
resource "google_project_iam_member" "controller" {
  project = var.project_id
  role    = google_project_iam_custom_role.controller.name
  member  = "serviceAccount:${google_service_account.fleet["controller"].email}"
}
resource "google_service_account_iam_member" "controller_worker" {
  service_account_id = google_service_account.fleet["worker"].name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.fleet["controller"].email}"
}
resource "google_project_iam_custom_role" "reaper" {
  role_id     = "${replace(var.prefix, "-", "_")}_reaper"
  title       = "SIM expired host reaper"
  permissions = ["compute.instances.list", "compute.instances.get", "compute.instances.delete", "compute.zoneOperations.get"]
}
resource "google_project_iam_member" "reaper" {
  project = var.project_id
  role    = google_project_iam_custom_role.reaper.name
  member  = "serviceAccount:${google_service_account.fleet["reaper"].email}"
}
resource "google_project_iam_member" "gateway" {
  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${google_service_account.fleet["gateway"].email}"
}
resource "google_project_iam_member" "owner_iap" {
  for_each = toset(var.admin_members)
  project  = var.project_id
  role     = "roles/iap.tunnelResourceAccessor"
  member   = each.value
}
resource "google_project_iam_member" "owner_login" {
  for_each = toset(var.admin_members)
  project  = var.project_id
  role     = "roles/compute.osAdminLogin"
  member   = each.value
}
resource "google_service_account_iam_member" "owner_login" {
  for_each           = { for item in setproduct(local.roles, toset(var.admin_members)) : "${item[0]}:${item[1]}" => item }
  service_account_id = google_service_account.fleet[each.value[0]].name
  role               = "roles/iam.serviceAccountUser"
  member             = each.value[1]
}

resource "google_secret_manager_secret" "tls" {
  for_each  = toset(["controller", "gateway", "collector"])
  secret_id = "${var.prefix}-${each.key}-tls"
  replication {
    auto {}
  }
}
resource "google_secret_manager_secret_iam_member" "tls" {
  for_each  = toset(["controller", "gateway", "collector"])
  secret_id = google_secret_manager_secret.tls[each.key].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.fleet[each.key].email}"
}

resource "google_compute_disk" "trusted" {
  for_each = local.trusted_roles
  name     = "${var.prefix}-${each.key}-state"
  type     = "pd-balanced"
  zone     = var.zones[0]
  size     = each.key == "controller" ? 100 : 20
  lifecycle { prevent_destroy = true }
}
resource "google_compute_instance" "trusted" {
  for_each     = local.trusted_roles
  name         = "${var.prefix}-${each.key}"
  zone         = var.zones[0]
  machine_type = each.key == "gateway" ? "e2-standard-4" : each.key == "controller" ? "e2-medium" : "e2-small"
  tags         = [var.prefix, "${var.prefix}-${each.key}"]
  boot_disk {
    initialize_params {
      image = var.trusted_host_image
      size = 20
    }
  }
  attached_disk {
    source = google_compute_disk.trusted[each.key].id
    device_name = "sim-state"
  }
  network_interface {
    subnetwork = google_compute_subnetwork.fleet.id
    network_ip = local.addresses[each.key]
  }
  service_account {
    email = google_service_account.fleet[each.key].email
    scopes = ["cloud-platform"]
  }
  metadata = { enable-oslogin = "TRUE", enable-oslogin-sk = "TRUE", sim-release-digest = var.release_digest }
  metadata_startup_script = templatefile("${path.module}/startup.sh.tftpl", {
    policy = base64encode(jsonencode(local.policy)), ca = base64encode(var.ca_certificate_pem)
    service = base64encode(jsonencode(merge(local.common_service, {
      tlsSecret = each.key == "reaper" ? "" : google_secret_manager_secret.tls[each.key].id
      role = each.key, port = each.key == "controller" ? 7660 : each.key == "gateway" ? 7661 : 7662
      collectorURL = "https://${local.addresses.collector}:7662", bucket = google_storage_bucket.audit.name
      controllerSubject = google_service_account.fleet["controller"].unique_id
      cert = "/etc/sim-fleet/tls/cert.pem", key = "/etc/sim-fleet/tls/key.pem"
      openaiProviderID = var.openai_provider_id, openaiServiceAccountID = var.openai_service_account_id
      vertexProject = var.project_id, vertexRegion = "us-east5"
    })))
    secret = each.key == "reaper" ? "" : google_secret_manager_secret.tls[each.key].id
    role = each.key
  })
  depends_on = [google_compute_router_nat.fleet, google_secret_manager_secret_iam_member.tls, google_project_iam_member.controller, google_project_iam_member.reaper]
}

resource "google_compute_instance_template" "worker" {
  name         = local.template_name
  machine_type = "n2-standard-32"
  tags         = [var.prefix, "${var.prefix}-worker"]
  advanced_machine_features { enable_nested_virtualization = true }
  disk {
    source_image = var.worker_host_image
    boot = true
    auto_delete = true
    disk_size_gb = 1000
    disk_type = "pd-ssd"
  }
  network_interface { subnetwork = google_compute_subnetwork.fleet.id }
  service_account {
    email = google_service_account.fleet["worker"].email
    scopes = ["cloud-platform"]
  }
  metadata = { enable-oslogin = "TRUE", enable-oslogin-sk = "TRUE", sim-release-digest = var.release_digest }
  metadata_startup_script = templatefile("${path.module}/startup.sh.tftpl", {
    policy = base64encode(jsonencode(local.policy)), ca = base64encode(var.ca_certificate_pem)
    service = base64encode(jsonencode(merge(local.common_service, { role = "worker", scratch = "/run/sim-worker" })))
    secret = "", role = "worker"
  })
}

resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "${var.prefix}-github"
  display_name              = "SIM GitHub deployments"
}
resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github"
  attribute_mapping = { "google.subject" = "assertion.sub", "attribute.repository_id" = "assertion.repository_id" }
  attribute_condition = "assertion.repository_id == '${var.github_repository_id}' && assertion.repository_owner_id == '${var.github_owner_id}' && assertion.job_workflow_ref == '${var.github_workflow_ref}' && assertion.ref == 'refs/heads/main'"
  oidc { issuer_uri = "https://token.actions.githubusercontent.com" }
}
resource "google_service_account_iam_member" "github" {
  service_account_id = google_service_account.fleet["deployer"].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository_id/${var.github_repository_id}"
}
