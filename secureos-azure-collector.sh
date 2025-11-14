#!/usr/bin/env bash
# SecureOS – Azure Evidence Setup (Federated Identity / AWS → Azure, config-only)
# - Creates App Registration and Service Principal in Azure AD
# - Grants least-privilege read-only roles (Reader, Security Reader, etc.)
# - Configures Federated Identity Credential to allow AWS role to impersonate the identity
# - Optional: verify and display setup details

set -euo pipefail

# ========= Hardcoded Constants (provided by SecureOS) =========
AWS_ACCOUNT_ID="294393683475"
AWS_ROLE_NAME="SecureOSAzureCollectorRole"
APP_REG_NAME="SecureOS-Evidence-Collector"
FEDERATION_CREDENTIAL_NAME="secureos-federation"

# ========= Defaults =========
DO_VERIFY="${DO_VERIFY:-0}"  # 1 => display detailed setup info after completion

usage() {
  cat <<USG >&2
Usage: $0 --subscription <SUBSCRIPTION_ID> [--verify]

Required:
  --subscription <SUBSCRIPTION_ID>    Azure subscription ID to grant access to

Optional:
  --verify                            Display detailed setup information after completion

Description:
  This script configures read-only access for SecureOS compliance evidence collection
  from your AWS infrastructure to your Azure subscription using Federated Identity.

  The script will:
  - Create an Azure AD App Registration and Service Principal
  - Assign read-only roles (Reader, Security Reader, Policy Insights Data Reader, Log Analytics Reader)
  - Configure Federated Identity to allow AWS role: ${AWS_ROLE_NAME}
  - No secrets or keys are created (uses workload identity federation)

Environment overrides:
  DO_VERIFY=1  (same as --verify flag)
USG
  exit 1
}

# ========= Parse arguments =========
SUBSCRIPTION_ID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --subscription) SUBSCRIPTION_ID="$2"; shift 2;;
    --verify) DO_VERIFY=1; shift;;
    *) usage;;
  esac
done

[[ -z "${SUBSCRIPTION_ID}" ]] && usage

# ========= Derived values =========
AWS_ROLE_ARN="arn:aws:sts::${AWS_ACCOUNT_ID}:assumed-role/${AWS_ROLE_NAME}"
FEDERATED_SUBJECT="${AWS_ROLE_ARN}/*"

echo ">> Subscription ID: ${SUBSCRIPTION_ID}"
echo ">> App Registration: ${APP_REG_NAME}"
echo ">> AWS Role ARN: ${AWS_ROLE_ARN}"

# ========= Prechecks =========
command -v az >/dev/null || { echo "ERROR: Azure CLI (az) not found. Please install it or use Azure Cloud Shell."; exit 1; }
command -v jq >/dev/null || { echo "ERROR: jq not found (Azure Cloud Shell includes jq)."; exit 1; }

# Check if logged in
ACTIVE_USER="$(az account show --query user.name -o tsv 2>/dev/null || true)"
[[ -z "$ACTIVE_USER" ]] && { echo "ERROR: Not logged in. Run: az login"; exit 1; }

echo ">> Logged in as: ${ACTIVE_USER}"

# Set active subscription
echo ">> Setting active subscription..."
az account set --subscription "${SUBSCRIPTION_ID}" >/dev/null

# Get tenant ID and subscription name for display
TENANT_ID="$(az account show --query tenantId -o tsv)"
SUBSCRIPTION_NAME="$(az account show --query name -o tsv)"
echo ">> Subscription: ${SUBSCRIPTION_NAME}"
echo ">> Tenant ID: ${TENANT_ID}"

# ========= Create App Registration (idempotent) =========
echo ">> Checking for existing App Registration..."
APP_ID="$(az ad app list --display-name "${APP_REG_NAME}" --query '[0].appId' -o tsv 2>/dev/null || true)"

if [[ -z "${APP_ID}" || "${APP_ID}" == "null" ]]; then
  echo ">> Creating App Registration: ${APP_REG_NAME}..."
  APP_ID="$(az ad app create --display-name "${APP_REG_NAME}" --query appId -o tsv)"
  echo ">> App Registration created with Client ID: ${APP_ID}"
else
  echo ">> App Registration already exists with Client ID: ${APP_ID}"
fi

# ========= Create Service Principal (idempotent) =========
echo ">> Checking for Service Principal..."
SP_OBJECT_ID="$(az ad sp list --filter "appId eq '${APP_ID}'" --query '[0].id' -o tsv 2>/dev/null || true)"

if [[ -z "${SP_OBJECT_ID}" || "${SP_OBJECT_ID}" == "null" ]]; then
  echo ">> Creating Service Principal..."
  SP_OBJECT_ID="$(az ad sp create --id "${APP_ID}" --query id -o tsv)"
  echo ">> Service Principal created with Object ID: ${SP_OBJECT_ID}"
  # Give Azure a moment to propagate the SP
  sleep 5
else
  echo ">> Service Principal already exists with Object ID: ${SP_OBJECT_ID}"
fi

# ========= Assign built-in roles (idempotent) =========
echo ">> Assigning read-only roles to Service Principal..."
SUBSCRIPTION_SCOPE="/subscriptions/${SUBSCRIPTION_ID}"

for ROLE in "Reader" "Security Reader" "Policy Insights Data Reader" "Log Analytics Reader"; do
  echo "   - Assigning role: ${ROLE}..."
  az role assignment create \
    --assignee "${SP_OBJECT_ID}" \
    --role "${ROLE}" \
    --scope "${SUBSCRIPTION_SCOPE}" \
    --output none 2>/dev/null || true
done

echo ">> Role assignments completed."

# ========= Configure Federated Identity Credential (idempotent) =========
echo ">> Configuring Federated Identity Credential for AWS role..."

# Check if federated credential already exists
EXISTING_FED_CRED="$(az ad app federated-credential list --id "${APP_ID}" --query "[?name=='${FEDERATION_CREDENTIAL_NAME}'].name" -o tsv 2>/dev/null || true)"

if [[ -z "${EXISTING_FED_CRED}" ]]; then
  echo ">> Creating Federated Identity Credential: ${FEDERATION_CREDENTIAL_NAME}..."
  
  # Create temporary JSON file for federated credential
  FED_CRED_FILE="/tmp/secureos-fed-cred-$$.json"
  cat > "${FED_CRED_FILE}" <<EOF
{
  "name": "${FEDERATION_CREDENTIAL_NAME}",
  "issuer": "https://sts.amazonaws.com",
  "subject": "${FEDERATED_SUBJECT}",
  "description": "Federated identity for SecureOS AWS role to access Azure",
  "audiences": [
    "api://AzureADTokenExchange"
  ]
}
EOF

  az ad app federated-credential create \
    --id "${APP_ID}" \
    --parameters "${FED_CRED_FILE}" \
    --output none
  
  rm -f "${FED_CRED_FILE}"
  echo ">> Federated Identity Credential created successfully."
else
  echo ">> Federated Identity Credential already exists: ${FEDERATION_CREDENTIAL_NAME}"
fi

# ========= Verification (optional) =========
if [[ "${DO_VERIFY}" -eq 1 ]]; then
  echo ""
  echo "=========================================="
  echo "SETUP VERIFICATION"
  echo "=========================================="
  echo ""
  echo "App Registration Details:"
  az ad app show --id "${APP_ID}" --query '{displayName:displayName, appId:appId, objectId:id}' -o json | jq
  echo ""
  echo "Service Principal Details:"
  az ad sp show --id "${APP_ID}" --query '{displayName:displayName, appId:appId, objectId:id}' -o json | jq
  echo ""
  echo "Role Assignments:"
  az role assignment list --assignee "${SP_OBJECT_ID}" --scope "${SUBSCRIPTION_SCOPE}" \
    --query '[].{Role:roleDefinitionName, Scope:scope}' -o table
  echo ""
  echo "Federated Identity Credentials:"
  az ad app federated-credential list --id "${APP_ID}" -o table
fi

# ========= Success output =========
echo ""
echo "=========================================="
echo "SUCCESS ✅"
echo "=========================================="
echo ""
echo "Configuration completed successfully!"
echo ""
echo "Details:"
echo "  Subscription ID:      ${SUBSCRIPTION_ID}"
echo "  Subscription Name:    ${SUBSCRIPTION_NAME}"
echo "  Tenant ID:            ${TENANT_ID}"
echo "  Application (Client) ID: ${APP_ID}"
echo "  Service Principal ID: ${SP_OBJECT_ID}"
echo ""
echo "Federated Identity:"
echo "  AWS Account:          ${AWS_ACCOUNT_ID}"
echo "  AWS Role:             ${AWS_ROLE_NAME}"
echo "  Subject:              ${FEDERATED_SUBJECT}"
echo ""
echo "Roles Assigned:"
echo "  - Reader"
echo "  - Security Reader"
echo "  - Policy Insights Data Reader"
echo "  - Log Analytics Reader"
echo ""
echo "Your AWS role (${AWS_ROLE_NAME}) can now access this Azure"
echo "subscription via Federated Identity Federation (no secrets required)."
echo ""
echo "Works from: EKS, EC2, Lambda, or any AWS service with IAM credentials"
echo ""

