#!/usr/bin/env bash
# Recria o que fica FORA do Terraform e que os pipelines precisam para rodar:
# bucket de state, pool de Workload Identity do GitHub Actions, a service
# account usada pelos workflows e os secrets que não são gerados por código.
#
# Só é necessário quando o projeto GCP foi limpo por completo. É idempotente:
# o que já existe é mantido.
#
#   NEW_RELIC_LICENSE_KEY=... ./scripts/bootstrap-gcp.sh
#
# Opcional (pagamento real no Billing):
#   MERCADOPAGO_ACCESS_TOKEN=TEST-... MERCADOPAGO_WEBHOOK_SECRET=... ./scripts/bootstrap-gcp.sh
set -euo pipefail

PROJETO=${PROJETO:-oficina-501820}
REGIAO=${REGIAO:-southamerica-east1}
DONO_GITHUB=${DONO_GITHUB:-robsonago}
BUCKET="${PROJETO}-tfstate"
SA_CI="github-actions-ci@${PROJETO}.iam.gserviceaccount.com"
NUMERO=$(gcloud projects describe "$PROJETO" --format='value(projectNumber)')

echo "→ APIs"
gcloud services enable --project "$PROJETO" container.googleapis.com compute.googleapis.com \
  iam.googleapis.com iamcredentials.googleapis.com sqladmin.googleapis.com secretmanager.googleapis.com \
  pubsub.googleapis.com apigateway.googleapis.com servicemanagement.googleapis.com \
  servicecontrol.googleapis.com cloudfunctions.googleapis.com run.googleapis.com \
  cloudbuild.googleapis.com artifactregistry.googleapis.com sts.googleapis.com

echo "→ Bucket de state do Terraform"
gcloud storage buckets describe "gs://$BUCKET" > /dev/null 2>&1 || \
  gcloud storage buckets create "gs://$BUCKET" --project "$PROJETO" --location "$REGIAO" --uniform-bucket-level-access
gcloud storage buckets update "gs://$BUCKET" --versioning > /dev/null

echo "→ Service account dos pipelines"
gcloud iam service-accounts describe "$SA_CI" --project "$PROJETO" > /dev/null 2>&1 || \
  gcloud iam service-accounts create github-actions-ci --project "$PROJETO" --display-name "GitHub Actions (CI/CD)"
for papel in roles/container.admin roles/cloudsql.admin roles/secretmanager.admin roles/pubsub.admin \
             roles/apigateway.admin roles/iam.serviceAccountAdmin roles/resourcemanager.projectIamAdmin \
             roles/compute.networkAdmin roles/storage.admin roles/cloudfunctions.developer \
             roles/run.admin roles/iam.serviceAccountUser roles/servicemanagement.admin roles/serviceusage.serviceUsageConsumer; do
  gcloud projects add-iam-policy-binding "$PROJETO" --member "serviceAccount:$SA_CI" --role "$papel" \
    --condition=None > /dev/null
done

echo "→ Workload Identity Federation (GitHub → GCP, só repositórios de $DONO_GITHUB)"
gcloud iam workload-identity-pools describe github-actions --location global --project "$PROJETO" > /dev/null 2>&1 || \
  gcloud iam workload-identity-pools create github-actions --location global --project "$PROJETO" \
    --display-name "GitHub Actions"
gcloud iam workload-identity-pools providers describe github --workload-identity-pool github-actions \
  --location global --project "$PROJETO" > /dev/null 2>&1 || \
  gcloud iam workload-identity-pools providers create-oidc github --workload-identity-pool github-actions \
    --location global --project "$PROJETO" --issuer-uri "https://token.actions.githubusercontent.com" \
    --attribute-mapping "google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner" \
    --attribute-condition "assertion.repository_owner == '$DONO_GITHUB'"
gcloud iam service-accounts add-iam-policy-binding "$SA_CI" --project "$PROJETO" \
  --role roles/iam.workloadIdentityUser \
  --member "principalSet://iam.googleapis.com/projects/$NUMERO/locations/global/workloadIdentityPools/github-actions/attribute.repository_owner/$DONO_GITHUB" > /dev/null

criar_secret() { # nome valor
  if ! gcloud secrets describe "$1" --project "$PROJETO" > /dev/null 2>&1; then
    gcloud secrets create "$1" --project "$PROJETO" --replication-policy automatic > /dev/null
  fi
  printf '%s' "$2" | gcloud secrets versions add "$1" --project "$PROJETO" --data-file=- > /dev/null
  echo "  secret $1 atualizado"
}

echo "→ Secrets"
if ! gcloud secrets describe oficina-jwt-secret --project "$PROJETO" > /dev/null 2>&1; then
  criar_secret oficina-jwt-secret "bXlTdXBlclNlY3JldEtleUZvckpXVFN5c3RlbU9maWNpbmFNZWNhbmljYTIwMjQ="
fi
if [ -n "${NEW_RELIC_LICENSE_KEY:-}" ]; then
  criar_secret newrelic-license-key "$NEW_RELIC_LICENSE_KEY"
elif ! gcloud secrets describe newrelic-license-key --project "$PROJETO" > /dev/null 2>&1; then
  echo "  ATENÇÃO: defina NEW_RELIC_LICENSE_KEY — o Terraform do cluster lê esse secret"
fi
[ -n "${MERCADOPAGO_ACCESS_TOKEN:-}" ] && criar_secret mercadopago-access-token "$MERCADOPAGO_ACCESS_TOKEN"
[ -n "${MERCADOPAGO_WEBHOOK_SECRET:-}" ] && criar_secret mercadopago-webhook-secret "$MERCADOPAGO_WEBHOOK_SECRET"

echo
echo "Pronto. Ordem para subir o ambiente:"
echo "  1. oficina-infra-db:  terraform apply   (Cloud SQL + bancos do OS e do Execution)"
echo "  2. oficina-infra-k8s: terraform apply   (GKE, Pub/Sub, IAM, configs, Gateway)"
echo "  3. kubectl apply -f manifests/<amb>/    (Ingress e certificado)"
echo "  4. variável GKE_DEPLOY_ENABLED=true nos repositórios dos serviços e push em homolog/main"
