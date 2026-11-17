# ════════════════════════════════════════════════════════════════════════
# Fase 4 — microsserviços e saga orquestrada
#
#   OS Service ──(comandos)──► oficina-billing-comandos-<amb>  ──► Billing
#   OS Service ──(comandos)──► oficina-execucao-comandos-<amb> ──► Execution
#   Billing / Execution ──(eventos)──► oficina-os-eventos-<amb> ──► OS Service
#
# Cada assinatura tem retry com backoff e, depois de 5 tentativas, a
# mensagem vai para a dead letter (oficina-saga-dlq-<amb>) para análise.
# ════════════════════════════════════════════════════════════════════════

data "google_project" "atual" {}

locals {
  ambientes = toset(["homolog", "producao"])

  namespaces = {
    homolog  = kubernetes_namespace.homolog.metadata[0].name
    producao = kubernetes_namespace.producao.metadata[0].name
  }

  topico_notificacoes = {
    homolog  = google_pubsub_topic.notificacoes_homolog.name
    producao = google_pubsub_topic.notificacoes_producao.name
  }

  gateway_host = {
    homolog  = google_api_gateway_gateway.homolog.default_hostname
    producao = google_api_gateway_gateway.producao.default_hostname
  }

  # Agente do próprio Pub/Sub: precisa publicar na DLQ e "consumir" das
  # assinaturas de origem para conseguir mover a mensagem.
  pubsub_agent = "serviceAccount:service-${data.google_project.atual.number}@gcp-sa-pubsub.iam.gserviceaccount.com"

  sa_os       = "serviceAccount:${var.app_cloudsql_service_account_email}"
  sa_billing  = "serviceAccount:${google_service_account.billing.email}"
  sa_execucao = "serviceAccount:${var.execucao_service_account_email}"
}

# ─────────────────────────── tópicos ───────────────────────────

resource "google_pubsub_topic" "billing_comandos" {
  for_each = local.ambientes
  name     = "oficina-billing-comandos-${each.key}"
}

resource "google_pubsub_topic" "execucao_comandos" {
  for_each = local.ambientes
  name     = "oficina-execucao-comandos-${each.key}"
}

resource "google_pubsub_topic" "os_eventos" {
  for_each = local.ambientes
  name     = "oficina-os-eventos-${each.key}"
}

resource "google_pubsub_topic" "saga_dlq" {
  for_each = local.ambientes
  name     = "oficina-saga-dlq-${each.key}"
}

# ─────────────────────────── assinaturas ───────────────────────────

resource "google_pubsub_subscription" "billing_comandos" {
  for_each                   = local.ambientes
  name                       = "oficina-billing-comandos-${each.key}-billing"
  topic                      = google_pubsub_topic.billing_comandos[each.key].id
  ack_deadline_seconds       = 30
  message_retention_duration = "604800s"

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "300s"
  }

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.saga_dlq[each.key].id
    max_delivery_attempts = 5
  }
}

resource "google_pubsub_subscription" "execucao_comandos" {
  for_each                   = local.ambientes
  name                       = "oficina-execucao-comandos-${each.key}-execucao"
  topic                      = google_pubsub_topic.execucao_comandos[each.key].id
  ack_deadline_seconds       = 30
  message_retention_duration = "604800s"

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "300s"
  }

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.saga_dlq[each.key].id
    max_delivery_attempts = 5
  }
}

resource "google_pubsub_subscription" "os_eventos" {
  for_each                   = local.ambientes
  name                       = "oficina-os-eventos-${each.key}-os"
  topic                      = google_pubsub_topic.os_eventos[each.key].id
  ack_deadline_seconds       = 30
  message_retention_duration = "604800s"

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "300s"
  }

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.saga_dlq[each.key].id
    max_delivery_attempts = 5
  }
}

# Só para inspecionar o que caiu na DLQ (gcloud pubsub subscriptions pull)
resource "google_pubsub_subscription" "saga_dlq" {
  for_each                   = local.ambientes
  name                       = "oficina-saga-dlq-${each.key}-inspecao"
  topic                      = google_pubsub_topic.saga_dlq[each.key].id
  message_retention_duration = "604800s"
}

# ─────────────────────────── IAM do Pub/Sub ───────────────────────────

resource "google_pubsub_topic_iam_member" "dlq_agente" {
  for_each = local.ambientes
  topic    = google_pubsub_topic.saga_dlq[each.key].name
  role     = "roles/pubsub.publisher"
  member   = local.pubsub_agent
}

locals {
  assinaturas_com_dlq = merge(
    { for a in local.ambientes : "billing-${a}" => google_pubsub_subscription.billing_comandos[a].name },
    { for a in local.ambientes : "execucao-${a}" => google_pubsub_subscription.execucao_comandos[a].name },
    { for a in local.ambientes : "os-${a}" => google_pubsub_subscription.os_eventos[a].name },
  )

  # quem pode publicar em qual tópico
  publicadores = merge(
    { for a in local.ambientes : "os-billing-${a}" => { topico = google_pubsub_topic.billing_comandos[a].name, membro = local.sa_os } },
    { for a in local.ambientes : "os-execucao-${a}" => { topico = google_pubsub_topic.execucao_comandos[a].name, membro = local.sa_os } },
    { for a in local.ambientes : "billing-eventos-${a}" => { topico = google_pubsub_topic.os_eventos[a].name, membro = local.sa_billing } },
    { for a in local.ambientes : "billing-notificacoes-${a}" => { topico = local.topico_notificacoes[a], membro = local.sa_billing } },
    { for a in local.ambientes : "execucao-eventos-${a}" => { topico = google_pubsub_topic.os_eventos[a].name, membro = local.sa_execucao } },
  )

  # quem consome de qual assinatura
  consumidores = merge(
    { for a in local.ambientes : "billing-${a}" => { assinatura = google_pubsub_subscription.billing_comandos[a].name, membro = local.sa_billing } },
    { for a in local.ambientes : "execucao-${a}" => { assinatura = google_pubsub_subscription.execucao_comandos[a].name, membro = local.sa_execucao } },
    { for a in local.ambientes : "os-${a}" => { assinatura = google_pubsub_subscription.os_eventos[a].name, membro = local.sa_os } },
  )
}

resource "google_pubsub_subscription_iam_member" "dlq_agente" {
  for_each     = local.assinaturas_com_dlq
  subscription = each.value
  role         = "roles/pubsub.subscriber"
  member       = local.pubsub_agent
}

resource "google_pubsub_topic_iam_member" "publicadores" {
  for_each = local.publicadores
  topic    = each.value.topico
  role     = "roles/pubsub.publisher"
  member   = each.value.membro
}

resource "google_pubsub_subscription_iam_member" "consumidores" {
  for_each     = local.consumidores
  subscription = each.value.assinatura
  role         = "roles/pubsub.subscriber"
  member       = each.value.membro
}

# ─────────────────────────── Billing Service ───────────────────────────

resource "google_service_account" "billing" {
  account_id   = "oficina-billing"
  display_name = "Billing Service - Pub/Sub"
}

resource "kubernetes_service_account" "billing" {
  for_each = local.ambientes
  metadata {
    name      = "oficina-billing"
    namespace = local.namespaces[each.key]
    annotations = {
      "iam.gke.io/gcp-service-account" = google_service_account.billing.email
    }
  }
}

resource "google_service_account_iam_member" "billing_workload_identity" {
  for_each           = local.ambientes
  service_account_id = google_service_account.billing.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${local.namespaces[each.key]}/oficina-billing]"
}

resource "random_password" "mongodb" {
  for_each = local.ambientes
  length   = 24
  special  = false
}

# Credenciais de root do MongoDB (StatefulSet no repo oficina-billing-service)
resource "kubernetes_secret" "billing_mongodb" {
  for_each = local.ambientes
  metadata {
    name      = "oficina-billing-mongodb"
    namespace = local.namespaces[each.key]
  }
  data = {
    MONGO_INITDB_ROOT_USERNAME = "billing"
    MONGO_INITDB_ROOT_PASSWORD = random_password.mongodb[each.key].result
  }
  type = "Opaque"
}

data "google_secret_manager_secret_version" "mercadopago_access_token" {
  count  = var.pagamento_provider == "mercadopago" ? 1 : 0
  secret = "mercadopago-access-token"
}

data "google_secret_manager_secret_version" "mercadopago_webhook_secret" {
  count  = var.pagamento_provider == "mercadopago" ? 1 : 0
  secret = "mercadopago-webhook-secret"
}

resource "kubernetes_secret" "billing" {
  for_each = local.ambientes
  metadata {
    name      = "oficina-billing-secret"
    namespace = local.namespaces[each.key]
  }
  data = {
    JWT_SECRET                 = local.jwt_secret
    MONGODB_URI                = "mongodb://billing:${random_password.mongodb[each.key].result}@oficina-billing-mongodb:27017/oficina_billing?authSource=admin"
    NEW_RELIC_LICENSE_KEY      = data.google_secret_manager_secret_version.newrelic_license_key.secret_data
    MERCADOPAGO_ACCESS_TOKEN   = var.pagamento_provider == "mercadopago" ? data.google_secret_manager_secret_version.mercadopago_access_token[0].secret_data : ""
    MERCADOPAGO_WEBHOOK_SECRET = var.pagamento_provider == "mercadopago" ? data.google_secret_manager_secret_version.mercadopago_webhook_secret[0].secret_data : ""
  }
  type = "Opaque"
}

resource "kubernetes_config_map" "billing" {
  for_each = local.ambientes
  metadata {
    name      = "oficina-billing-config"
    namespace = local.namespaces[each.key]
  }
  data = {
    SERVER_PORT                  = "8080"
    MENSAGERIA_PROVIDER          = "pubsub"
    PUBSUB_PROJECT_ID            = var.project_id
    PUBSUB_ASSINATURA_COMANDOS   = google_pubsub_subscription.billing_comandos[each.key].name
    PUBSUB_TOPICO_OS_EVENTOS     = google_pubsub_topic.os_eventos[each.key].name
    PUBSUB_TOPICO_NOTIFICACOES   = local.topico_notificacoes[each.key]
    PAGAMENTO_PROVIDER           = var.pagamento_provider
    PAGAMENTO_SIMULADO_LINK_BASE = "https://${local.gateway_host[each.key]}/api/pagamentos/simulacao"
    MERCADOPAGO_NOTIFICATION_URL = "https://${local.gateway_host[each.key]}/api/pagamentos/webhook"
    MERCADOPAGO_SANDBOX          = each.key == "producao" ? "false" : "true"
    NEW_RELIC_APP_NAME           = "oficina-billing-${each.key}"
  }
}

# ─────────────────────────── Execution Service ───────────────────────────

data "google_secret_manager_secret_version" "execucao_db_password" {
  secret = "oficina-execucao-db-password"
}

resource "google_secret_manager_secret_iam_member" "execucao_le_newrelic" {
  secret_id = "newrelic-license-key"
  role      = "roles/secretmanager.secretAccessor"
  member    = local.sa_execucao
}

resource "kubernetes_service_account" "execucao" {
  for_each = local.ambientes
  metadata {
    name      = "oficina-execution"
    namespace = local.namespaces[each.key]
    annotations = {
      "iam.gke.io/gcp-service-account" = var.execucao_service_account_email
    }
  }
}

resource "google_service_account_iam_member" "execucao_workload_identity" {
  for_each           = local.ambientes
  service_account_id = "projects/${var.project_id}/serviceAccounts/${var.execucao_service_account_email}"
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${local.namespaces[each.key]}/oficina-execution]"
}

resource "kubernetes_secret" "execucao" {
  for_each = local.ambientes
  metadata {
    name      = "oficina-execution-secret"
    namespace = local.namespaces[each.key]
  }
  data = {
    DB_USERNAME           = "execucao"
    DB_PASSWORD           = data.google_secret_manager_secret_version.execucao_db_password.secret_data
    DB_URL                = "jdbc:postgresql://127.0.0.1:5432/execucao_${each.key}"
    JWT_SECRET            = local.jwt_secret
    NEW_RELIC_LICENSE_KEY = data.google_secret_manager_secret_version.newrelic_license_key.secret_data
  }
  type = "Opaque"
}

resource "kubernetes_config_map" "execucao" {
  for_each = local.ambientes
  metadata {
    name      = "oficina-execution-config"
    namespace = local.namespaces[each.key]
  }
  data = {
    SERVER_PORT                = "8080"
    DB_POOL_MAXIMO             = "3"
    MENSAGERIA_PROVIDER        = "pubsub"
    PUBSUB_PROJECT_ID          = var.project_id
    PUBSUB_ASSINATURA_COMANDOS = google_pubsub_subscription.execucao_comandos[each.key].name
    PUBSUB_TOPICO_OS_EVENTOS   = google_pubsub_topic.os_eventos[each.key].name
    NEW_RELIC_APP_NAME         = "oficina-execution-${each.key}"
  }
}
