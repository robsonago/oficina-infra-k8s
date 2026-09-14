# ──────────────────────────────────────────
# Cluster GKE (zonal, custo baixo)
# ──────────────────────────────────────────
resource "google_container_cluster" "oficina" {
  name     = var.cluster_name
  location = var.zone

  # Gerenciamos o node pool separadamente (padrão recomendado pelo provider):
  # cria o cluster sem o pool default e remove o node pool inicial.
  remove_default_node_pool = true
  initial_node_count       = 1

  deletion_protection = false

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  release_channel {
    channel = "REGULAR"
  }
}

resource "google_container_node_pool" "primary" {
  name     = "${var.cluster_name}-pool"
  location = var.zone
  cluster  = google_container_cluster.oficina.name

  node_count = var.node_count

  node_config {
    machine_type = var.machine_type
    preemptible  = var.preemptible
    disk_size_gb = 20
    disk_type    = "pd-standard"

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]
  }

  autoscaling {
    min_node_count = 1
    max_node_count = var.node_count
  }
}

# ──────────────────────────────────────────
# Namespaces: homologação e produção
# (mesmo cluster, dois "compartimentos" isolados, para não pagar por dois
# clusters inteiros — ver docs/plano-execucao-fase3-gcp.md, item 13).
# ──────────────────────────────────────────
resource "kubernetes_namespace" "homolog" {
  metadata {
    name = "oficina-homolog"
  }

  depends_on = [google_container_node_pool.primary]
}

resource "kubernetes_namespace" "producao" {
  metadata {
    name = "oficina-producao"
  }

  depends_on = [google_container_node_pool.primary]
}

# ──────────────────────────────────────────
# Credenciais do banco (lidas do Secret Manager, criado em oficina-infra-db)
# ──────────────────────────────────────────
data "google_secret_manager_secret_version" "db_password" {
  secret = "oficina-db-password"
}

data "google_secret_manager_secret_version" "db_url_homolog" {
  secret = "oficina-db-url-homolog"
}

data "google_secret_manager_secret_version" "db_url_producao" {
  secret = "oficina-db-url-producao"
}

locals {
  db_user = "oficina"

  # Mesmos valores usados hoje em k8s/secret.yaml (Fase 2), reaproveitados
  # por ambiente até a Parte 5 (notificação via Pub/Sub) trocar esse fluxo.
  jwt_secret = "bXlTdXBlclNlY3JldEtleUZvckpXVFN5c3RlbU9maWNpbmFNZWNhbmljYTIwMjQ="
}

resource "kubernetes_secret" "oficina_homolog" {
  metadata {
    name      = "oficina-secret"
    namespace = kubernetes_namespace.homolog.metadata[0].name
  }

  data = {
    DB_USERNAME = local.db_user
    DB_PASSWORD = data.google_secret_manager_secret_version.db_password.secret_data
    DB_URL      = data.google_secret_manager_secret_version.db_url_homolog.secret_data
    JWT_SECRET  = local.jwt_secret
  }

  type = "Opaque"
}

resource "kubernetes_secret" "oficina_producao" {
  metadata {
    name      = "oficina-secret"
    namespace = kubernetes_namespace.producao.metadata[0].name
  }

  data = {
    DB_USERNAME = local.db_user
    DB_PASSWORD = data.google_secret_manager_secret_version.db_password.secret_data
    DB_URL      = data.google_secret_manager_secret_version.db_url_producao.secret_data
    JWT_SECRET  = local.jwt_secret
  }

  type = "Opaque"
}

resource "kubernetes_config_map" "oficina_homolog" {
  metadata {
    name      = "oficina-config"
    namespace = kubernetes_namespace.homolog.metadata[0].name
  }

  data = {
    JWT_EXPIRATION = "86400000"
    SERVER_PORT    = "8080"
  }
}

resource "kubernetes_config_map" "oficina_producao" {
  metadata {
    name      = "oficina-config"
    namespace = kubernetes_namespace.producao.metadata[0].name
  }

  data = {
    JWT_EXPIRATION = "86400000"
    SERVER_PORT    = "8080"
  }
}

# ──────────────────────────────────────────
# Workload Identity: a Service Account de cada namespace pode assumir a
# identidade da service account do GCP criada em oficina-infra-db
# (google_service_account.app_cloudsql), para autenticar no Cloud SQL Auth
# Proxy sem chave de serviço em arquivo.
# ──────────────────────────────────────────
resource "kubernetes_service_account" "app_homolog" {
  metadata {
    name      = "oficina-app"
    namespace = kubernetes_namespace.homolog.metadata[0].name
    annotations = {
      "iam.gke.io/gcp-service-account" = var.app_cloudsql_service_account_email
    }
  }
}

resource "kubernetes_service_account" "app_producao" {
  metadata {
    name      = "oficina-app"
    namespace = kubernetes_namespace.producao.metadata[0].name
    annotations = {
      "iam.gke.io/gcp-service-account" = var.app_cloudsql_service_account_email
    }
  }
}

resource "google_service_account_iam_member" "workload_identity_homolog" {
  service_account_id = "projects/${var.project_id}/serviceAccounts/${var.app_cloudsql_service_account_email}"
  role                = "roles/iam.workloadIdentityUser"
  member              = "serviceAccount:${var.project_id}.svc.id.goog[oficina-homolog/oficina-app]"
}

resource "google_service_account_iam_member" "workload_identity_producao" {
  service_account_id = "projects/${var.project_id}/serviceAccounts/${var.app_cloudsql_service_account_email}"
  role                = "roles/iam.workloadIdentityUser"
  member              = "serviceAccount:${var.project_id}.svc.id.goog[oficina-producao/oficina-app]"
}

# ──────────────────────────────────────────
# IPs estáticos globais + certificados gerenciados para expor a aplicação
# via HTTPS público (exigido pelo backend do API Gateway).
# Usa nip.io (hostname = IP + ".nip.io") em vez de um domínio próprio.
# ──────────────────────────────────────────
resource "google_compute_global_address" "homolog" {
  name = "oficina-homolog-ip"
}

resource "google_compute_global_address" "producao" {
  name = "oficina-producao-ip"
}

# ──────────────────────────────────────────
# API Gateway — porta de entrada pública única, na frente da aplicação.
# Um API Config + Gateway por ambiente (homolog/produção), cada um apontando
# para o respectivo host HTTPS (Ingress + certificado gerenciado, acima).
# ──────────────────────────────────────────
resource "google_api_gateway_api" "oficina" {
  provider = google-beta
  api_id   = "oficina-api"
}

resource "google_api_gateway_api_config" "homolog" {
  provider              = google-beta
  api                   = google_api_gateway_api.oficina.api_id
  api_config_id_prefix  = "homolog-"

  openapi_documents {
    document {
      path     = "openapi.yaml"
      contents = filebase64("${path.module}/gateway/homolog.yaml")
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "google_api_gateway_gateway" "homolog" {
  provider   = google-beta
  api_config = google_api_gateway_api_config.homolog.id
  gateway_id = "oficina-gateway-homolog"
  region     = var.gateway_region
}

resource "google_api_gateway_api_config" "producao" {
  provider              = google-beta
  api                   = google_api_gateway_api.oficina.api_id
  api_config_id_prefix  = "producao-"

  openapi_documents {
    document {
      path     = "openapi.yaml"
      contents = filebase64("${path.module}/gateway/producao.yaml")
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "google_api_gateway_gateway" "producao" {
  provider   = google-beta
  api_config = google_api_gateway_api_config.producao.id
  gateway_id = "oficina-gateway-producao"
  region     = var.gateway_region
}
