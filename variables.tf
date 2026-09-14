variable "project_id" {
  description = "ID do projeto GCP (ex.: oficina-501820)"
  type        = string
}

variable "region" {
  description = "Região do cluster (usada para o provider; o cluster em si é zonal)"
  type        = string
  default     = "southamerica-east1"
}

variable "zone" {
  description = "Zona do cluster GKE. Cluster zonal (não regional) para se qualificar ao free tier de 1 cluster zonal sem taxa de gerenciamento por billing account, e para reduzir custo (menos réplicas do control plane)."
  type        = string
  default     = "southamerica-east1-a"
}

variable "cluster_name" {
  description = "Nome do cluster GKE"
  type        = string
  default     = "oficina-gke"
}

variable "machine_type" {
  description = "Tipo de máquina dos nós. e2-small/e2-medium têm a mesma contagem nominal de vCPU (2), então o Kubernetes reserva a mesma fatia fixa de CPU para os add-ons gerenciados do GKE nos dois casos, sobrando pouco pros pods da aplicação. e2-standard-4 dilui essa taxa fixa contra mais vCPUs de verdade."
  type        = string
  default     = "e2-standard-4"
}

variable "node_count" {
  description = "Número de nós do node pool (fixo; o autoscaling de carga é feito pelo HPA em nível de Pod, não de nó, para manter custo previsível). 1 nó só, sem redundância — aceitável para ambiente de estudo."
  type        = number
  default     = 1
}

variable "preemptible" {
  description = "Usa nós preemptible/spot (bem mais baratos, aceitável para ambiente de estudo/homologação)"
  type        = bool
  default     = true
}

variable "app_cloudsql_service_account_email" {
  description = "E-mail da service account criada em oficina-infra-db (google_service_account.app_cloudsql), usada via Workload Identity para o Cloud SQL Auth Proxy"
  type        = string
}

variable "gateway_region" {
  description = "Região do API Gateway (southamerica-east1 não é suportada pelo produto; usamos a região suportada mais próxima)"
  type        = string
  default     = "us-east1"
}

variable "cloudsql_instance_connection_name" {
  description = "Connection name da instância Cloud SQL (projeto:região:instância), usado pelo Cloud SQL Auth Proxy"
  type        = string
}
