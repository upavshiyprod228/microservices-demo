# Copyright 2022 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Definition of local variables
locals {
  base_apis = [
    "container.googleapis.com",
    "monitoring.googleapis.com",
    "cloudtrace.googleapis.com",
    "cloudprofiler.googleapis.com"
  ]
  memorystore_apis = ["redis.googleapis.com"]
  cluster_name     = google_container_cluster.my_cluster.name
  # Use a single zone for a predictable node count (avoids multi-zone node multiplication)
  zone = "${var.region}-b"
}

# Enable Google Cloud APIs
module "enable_google_apis" {
  source  = "terraform-google-modules/project-factory/google//modules/project_services"
  version = "~> 18.0"

  project_id                  = var.gcp_project_id
  disable_services_on_destroy = false

  # activate_apis is the set of base_apis and the APIs required by user-configured deployment options
  activate_apis = concat(local.base_apis, var.memorystore ? local.memorystore_apis : [])
}

# Create GKE standard cluster (zonal, us-central1-b)
resource "google_container_cluster" "my_cluster" {

  name     = var.name
  location = local.zone

  # Remove the default node pool after cluster creation;
  # we manage nodes via a separate google_container_node_pool resource
  remove_default_node_pool = true
  initial_node_count       = 1

  # Avoid setting deletion_protection to false
  # until you're ready (and certain you want) to destroy the cluster.
  deletion_protection = false

  depends_on = [
    module.enable_google_apis
  ]
}

# Node pool: 3x e2-standard-4 nodes (4 vCPU / 16 GB RAM each = 12 vCPU / 48 GB total)
resource "google_container_node_pool" "primary_nodes" {
  name       = "${var.name}-node-pool"
  location   = local.zone
  cluster    = google_container_cluster.my_cluster.name
  node_count = 3

  node_config {
    machine_type = "e2-standard-4"
    disk_size_gb = 50

    # Full access to GCP APIs (required for pulling images, logging, etc.)
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }
}

# Get credentials for cluster
module "gcloud" {
  source  = "terraform-google-modules/gcloud/google"
  version = "~> 4.0"

  platform              = "linux"
  additional_components = ["kubectl", "beta"]

  create_cmd_entrypoint = "gcloud"
  # Module does not support explicit dependency
  # Enforce implicit dependency through use of local variable
  create_cmd_body = "container clusters get-credentials ${local.cluster_name} --zone=${local.zone} --project=${var.gcp_project_id}"
}

# Create staging and prod namespaces
resource "null_resource" "create_namespaces" {
  provisioner "local-exec" {
    interpreter = ["bash", "-exc"]
    command     = <<-EOT
      kubectl create namespace staging --dry-run=client -o yaml | kubectl apply -f -
      kubectl create namespace prod    --dry-run=client -o yaml | kubectl apply -f -
      kubectl label namespace staging environment=staging --overwrite
      kubectl label namespace prod    environment=prod    --overwrite
    EOT
  }

  depends_on = [
    module.gcloud
  ]
}

# Deploy Online Boutique to staging namespace
resource "null_resource" "deploy_staging" {
  provisioner "local-exec" {
    interpreter = ["bash", "-exc"]
    command     = "kubectl apply -k ${path.module}/../kustomize/overlays/staging"
  }

  depends_on = [
    null_resource.create_namespaces
  ]
}

# Deploy Online Boutique to prod namespace
resource "null_resource" "deploy_prod" {
  provisioner "local-exec" {
    interpreter = ["bash", "-exc"]
    command     = "kubectl apply -k ${path.module}/../kustomize/overlays/prod"
  }

  depends_on = [
    null_resource.create_namespaces
  ]
}

# Wait condition for all Pods to be ready before finishing
resource "null_resource" "wait_conditions" {
  provisioner "local-exec" {
    interpreter = ["bash", "-exc"]
    command     = <<-EOT
      kubectl wait --for=condition=AVAILABLE apiservice/v1beta1.metrics.k8s.io --timeout=180s || echo "Metrics API not yet available on Autopilot, continuing..."
      kubectl wait --for=condition=ready pods --all -n staging --timeout=600s
      kubectl wait --for=condition=ready pods --all -n prod    --timeout=600s
    EOT
  }

  depends_on = [
    null_resource.deploy_staging,
    null_resource.deploy_prod,
  ] 
}
