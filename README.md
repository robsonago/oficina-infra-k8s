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
`Service` é `ClusterIP`: o tráfego externo entra por um `Ingress` (ver
abaixo), não diretamente pelo Service. O deploy automático desses manifests
via CI/CD ainda será configurado; até lá, o `imagePullSecret` `ghcr-secret`
de cada namespace precisa ser criado manualmente
(`kubectl create secret docker-registry`) com um token de leitura do GHCR —
ou o pacote `oficina-app` no GHCR precisa ser tornado público.

### Exposição pública HTTPS + API Gateway

Cada namespace tem um IP estático global reservado (Terraform,
`google_compute_global_address`), um `Ingress` (classe `gce`) e um
`ManagedCertificate` apontando para um hostname
[nip.io](https://nip.io) construído a partir desse IP (ex.:
`34.120.1.2.nip.io`) — assim a aplicação fica disponível via HTTPS público
com certificado confiável, sem precisar de domínio próprio. Isso é exigido
porque o backend do Google API Gateway só aceita endereços HTTPS.

Na frente disso, [`gateway/`](gateway) tem a especificação OpenAPI 2.0
(Swagger) usada para criar o Google API Gateway — uma API com um
`API Config`/`Gateway` por ambiente (`oficina-gateway-homolog` e
`oficina-gateway-producao`, região `us-east1`; API Gateway não está
disponível em `southamerica-east1`). O gateway repassa o path original para
o backend (`x-google-backend`) e documenta, por rota, quais exigem token
(`security: [{bearerAuth: []}]`) — a validação de fato do JWT continua na
aplicação (Spring Security), já que o esquema atual (HMAC com chave
compartilhada) não é compatível com a validação nativa de JWT do API
Gateway, que exige um emissor com chaves públicas (JWKS). A rota de
autenticação por CPF (Cloud Function) será adicionada ao spec quando essa
function existir.

`gateway/oficina-gateway.template.yaml` é a fonte única; `gateway/homolog.yaml`
e `gateway/producao.yaml` são gerados substituindo o host do
`x-google-backend`.

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
- `homolog_hostname`/`producao_hostname`: hostnames nip.io usados pelo
  `ManagedCertificate` e pelo `x-google-backend` do gateway.
- `gateway_homolog_url`/`gateway_producao_url`: URL pública de cada
  ambiente — é por aqui que a API deve ser chamada (não diretamente pelo
  hostname nip.io).

> Este README será complementado com diagrama de arquitetura conforme o
> restante do trabalho avança.
