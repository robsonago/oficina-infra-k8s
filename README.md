# oficina-infra-k8s

Infraestrutura do Cluster Kubernetes (Terraform) do Tech Challenge Fase 3
(Pós-Tech SOAT).

Um dos 4 repositórios exigidos pelo desafio, responsável por provisionar o
cluster Kubernetes gerenciado (GKE) que roda a aplicação principal
([`oficina`](https://github.com/robsonago/oficina)), com dois namespaces
isolados — `oficina-homolog` e `oficina-producao` — dentro do mesmo cluster,
em vez de dois clusters inteiros.

Dockerfile não se aplica a este repositório (Terraform não usa Docker).

## Stack

- Terraform >= 1.6
- Provider `hashicorp/google` ~> 6.0 e `hashicorp/kubernetes` ~> 2.31
- GKE (cluster zonal, Workload Identity habilitado)
- Node pool: `e2-small`, preemptible, 1-2 nós com autoscaling de nó
- State remoto em bucket GCS (`oficina-501820-tfstate`, prefixo `infra-k8s`)

## O que este repositório provisiona

- Cluster GKE zonal `oficina-gke` (`southamerica-east1-a`), sem node pool
  default (gerenciado separadamente para permitir tuning de custo).
- Node pool próprio com nós preemptible `e2-small` (mais barato, adequado para
  ambiente de estudo) e autoscaling entre 1 e `var.node_count` nós.
- Namespaces `oficina-homolog` e `oficina-producao`.
- Um `Secret` (`oficina-secret`) por namespace, com as credenciais do banco
  lidas do Secret Manager (criado em
  [`oficina-infra-db`](https://github.com/robsonago/oficina-infra-db)) —
  cada namespace aponta para o banco correspondente
  (`oficina_homolog`/`oficina_producao`).
- Um `ConfigMap` (`oficina-config`) por namespace com configuração não
  sensível da aplicação.
- Uma `ServiceAccount` do Kubernetes (`oficina-app`) por namespace, vinculada
  via Workload Identity à service account do GCP `oficina-app-cloudsql`
  (criada em `oficina-infra-db`), para autenticar no Cloud SQL sem chave de
  serviço em arquivo.

Os manifests da aplicação (`Deployment`/`Service`/`HPA`) estão em
[`manifests/homolog`](manifests/homolog) e
[`manifests/producao`](manifests/producao) — um conjunto por ambiente. O
`Service` usa `type: LoadBalancer` (IP público real), adequado para cloud.
O deploy automático desses manifests via CI/CD ainda será configurado; até
lá, o `imagePullSecret` `ghcr-secret` de cada namespace precisa ser criado
manualmente (`kubectl create secret docker-registry`) com um token de leitura
do GHCR.

## Pré-requisitos

- `gcloud` autenticado (`gcloud auth application-default login`) e projeto
  configurado (`gcloud config set project oficina-501820`).
- APIs habilitadas: `container.googleapis.com`, `compute.googleapis.com`,
  `iam.googleapis.com`.
- Bucket de state já criado (`oficina-501820-tfstate`).
- `oficina-infra-db` já aplicado (os secrets `oficina-db-password`,
  `oficina-db-url-homolog` e `oficina-db-url-producao` precisam existir no
  Secret Manager antes do `apply` deste repositório).

## Como rodar

```bash
terraform init
terraform plan -var-file=terraform.tfvars    # copie terraform.tfvars.example
terraform apply -var-file=terraform.tfvars
```

Depois do apply, configure o `kubectl` local:

```bash
gcloud container clusters get-credentials oficina-gke \
  --zone southamerica-east1-a --project oficina-501820
kubectl get ns
```

## Saídas relevantes

- `get_credentials_command`: comando pronto para configurar o `kubectl`.
- `namespaces`: os dois namespaces criados.

> Este README será complementado com diagrama de arquitetura e link dos
> ambientes ativos (IP dos `LoadBalancer`, ou a URL do API Gateway quando ele
> for configurado na frente da aplicação).
