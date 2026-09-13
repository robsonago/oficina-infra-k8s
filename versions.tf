terraform {
  required_version = ">= 1.6"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.31"
    }
  }

  backend "gcs" {
    bucket = "oficina-501820-tfstate"
    prefix = "infra-k8s"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

data "google_client_config" "default" {}

provider "kubernetes" {
  host                   = "https://${google_container_cluster.oficina.endpoint}"
  cluster_ca_certificate = base64decode(google_container_cluster.oficina.master_auth[0].cluster_ca_certificate)
  token                  = data.google_client_config.default.access_token
}
