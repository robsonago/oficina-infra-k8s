output "cluster_name" {
  value = google_container_cluster.oficina.name
}

output "cluster_endpoint" {
  description = "Endpoint do control plane (usar 'gcloud container clusters get-credentials' em vez de copiar isso manualmente)"
  value       = google_container_cluster.oficina.endpoint
  sensitive   = true
}

output "cluster_location" {
  value = google_container_cluster.oficina.location
}

output "namespaces" {
  value = [
    kubernetes_namespace.homolog.metadata[0].name,
    kubernetes_namespace.producao.metadata[0].name,
  ]
}

output "get_credentials_command" {
  description = "Comando para configurar o kubectl local apontando para este cluster"
  value       = "gcloud container clusters get-credentials ${google_container_cluster.oficina.name} --zone ${var.zone} --project ${var.project_id}"
}

output "homolog_ip" {
  value = google_compute_global_address.homolog.address
}

output "producao_ip" {
  value = google_compute_global_address.producao.address
}

output "homolog_hostname" {
  value = "${google_compute_global_address.homolog.address}.nip.io"
}

output "producao_hostname" {
  value = "${google_compute_global_address.producao.address}.nip.io"
}

output "gateway_homolog_url" {
  value = "https://${google_api_gateway_gateway.homolog.default_hostname}"
}

output "gateway_producao_url" {
  value = "https://${google_api_gateway_gateway.producao.default_hostname}"
}
