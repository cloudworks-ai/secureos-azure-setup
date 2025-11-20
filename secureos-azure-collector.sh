#!/usr/bin/env bash
# SecureOS – Azure Evidence Setup (Client Secret Authentication)
# - Creates App Registration and Service Principal in Azure AD
# - Grants least-privilege read-only roles (Reader, Security Reader, etc.)
# - Generates a client secret for authentication
# - Optional: verify and display setup details

set -euo pipefail

# ========= Hardcoded Constants =========
# Azure App Registration name
APP_REG_NAME="SecureOS-Collector"
# Client secret validity (in years)
SECRET_VALIDITY_YEARS=2

# ========= Defaults =========
DO_VERIFY="${DO_VERIFY:-0}"  # 1 => display detailed setup info after completion

usage() {
  cat <<USG >&2
Usage: $0 --subscription-id <SUBSCRIPTION_ID> [--verify]

Required:
  --subscription-id <SUBSCRIPTION_ID>    Azure subscription ID to grant access to

Optional:
  --verify                               Display detailed setup information after completion

Description:
  This script configures read-only access for SecureOS compliance evidence collection
  from your Azure subscription using client secret authentication.
  
  The script will:
  - Create an Azure AD App Registration and Service Principal named: ${APP_REG_NAME}
  - Generate a client secret (valid for ${SECRET_VALIDITY_YEARS} years)
  - Assign read-only roles (Reader, Security Reader, Log Analytics Reader)
  - Grant Microsoft Graph API permissions (User.Read.All, Directory.Read.All, GroupMember.Read.All, AuditLog.Read.All)
  - Display the credentials needed for SecureOS to access your Azure subscription

Environment overrides:
  DO_VERIFY=1  (same as --verify flag)

Example:
  curl -sL https://raw.githubusercontent.com/cloudworks-ai/secureos-azure-setup/main/secureos-azure-collector.sh | bash -s -- --subscription-id <SUB_ID>
USG
  exit 1
}

# ========= Parse arguments =========
SUBSCRIPTION_ID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --subscription|--subscription-id) SUBSCRIPTION_ID="$2"; shift 2;;
    --verify) DO_VERIFY=1; shift;;
    *) usage;;
  esac
done

[[ -z "${SUBSCRIPTION_ID}" ]] && usage

echo "=========================================="
echo "SecureOS Azure Onboarding"
echo "=========================================="
echo ""
echo "This script will configure Azure to allow SecureOS"
echo "to access your Azure subscription."
echo ""
echo ">> Target Subscription: ${SUBSCRIPTION_ID}"
echo ">> App Registration: ${APP_REG_NAME}"
echo ""

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

for ROLE in "Reader" "Security Reader" "Log Analytics Reader"; do
  echo "   - Assigning role: ${ROLE}..."
  az role assignment create \
    --assignee "${SP_OBJECT_ID}" \
    --role "${ROLE}" \
    --scope "${SUBSCRIPTION_SCOPE}" \
    --output none 2>/dev/null || true
done

echo ">> Role assignments completed."

# ========= Assign Microsoft Graph API Permissions (idempotent) =========
echo ">> Configuring Microsoft Graph API permissions for Azure AD access..."

# Microsoft Graph Application ID (constant across all Azure AD tenants)
MSGRAPH_APP_ID="00000003-0000-0000-c000-000000000000"

# Permission IDs for Microsoft Graph (these are constant GUIDs)
USER_READ_ALL_ID="df021288-bdef-4463-88db-98f22de89214"           # User.Read.All
DIRECTORY_READ_ALL_ID="7ab1d382-f21e-4acd-a863-ba3e13f7da61"      # Directory.Read.All
GROUPMEMBER_READ_ALL_ID="98830695-27a2-44f7-8c18-0c3ebc9698f6"    # GroupMember.Read.All
AUDITLOG_READ_ALL_ID="b0afded3-3588-46d8-8b3d-9842eff778da"       # AuditLog.Read.All

# Check existing permissions
EXISTING_PERMS=$(az ad app permission list --id "${APP_ID}" --query "[?resourceAppId=='${MSGRAPH_APP_ID}'].resourceAccess[].id" -o tsv 2>/dev/null || true)

# Add User.Read.All if not present
if echo "${EXISTING_PERMS}" | grep -q "${USER_READ_ALL_ID}"; then
  echo "   - User.Read.All already assigned"
else
  echo "   - Adding User.Read.All (Application permission)..."
  az ad app permission add \
    --id "${APP_ID}" \
    --api ${MSGRAPH_APP_ID} \
    --api-permissions ${USER_READ_ALL_ID}=Role 2>/dev/null || true
fi

# Add Directory.Read.All if not present
if echo "${EXISTING_PERMS}" | grep -q "${DIRECTORY_READ_ALL_ID}"; then
  echo "   - Directory.Read.All already assigned"
else
  echo "   - Adding Directory.Read.All (Application permission)..."
  az ad app permission add \
    --id "${APP_ID}" \
    --api ${MSGRAPH_APP_ID} \
    --api-permissions ${DIRECTORY_READ_ALL_ID}=Role 2>/dev/null || true
fi

# Add GroupMember.Read.All if not present
if echo "${EXISTING_PERMS}" | grep -q "${GROUPMEMBER_READ_ALL_ID}"; then
  echo "   - GroupMember.Read.All already assigned"
else
  echo "   - Adding GroupMember.Read.All (Application permission)..."
  az ad app permission add \
    --id "${APP_ID}" \
    --api ${MSGRAPH_APP_ID} \
    --api-permissions ${GROUPMEMBER_READ_ALL_ID}=Role 2>/dev/null || true
fi

# Add AuditLog.Read.All if not present
if echo "${EXISTING_PERMS}" | grep -q "${AUDITLOG_READ_ALL_ID}"; then
  echo "   - AuditLog.Read.All already assigned"
else
  echo "   - Adding AuditLog.Read.All (Application permission)..."
  az ad app permission add \
    --id "${APP_ID}" \
    --api ${MSGRAPH_APP_ID} \
    --api-permissions ${AUDITLOG_READ_ALL_ID}=Role 2>/dev/null || true
fi

echo "   - Granting admin consent for API permissions..."

# Get Microsoft Graph Service Principal ID
MSGRAPH_SP_ID=$(az ad sp show --id "${MSGRAPH_APP_ID}" --query "id" -o tsv)

# Get our app's Service Principal ID
SP_ID="${SP_OBJECT_ID}"

# Function to grant individual permission
grant_permission() {
  local PERM_ID=$1
  local PERM_NAME=$2
  
  # Check if already granted
  EXISTING_GRANT=$(az rest --method GET \
    --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${SP_ID}/appRoleAssignments" 2>/dev/null | \
    jq -r ".value[] | select(.appRoleId==\"${PERM_ID}\") | .id" 2>/dev/null)
  
  if [[ -n "${EXISTING_GRANT}" ]]; then
    echo "      ✅ ${PERM_NAME} already consented"
    return 0
  fi
  
  # Grant the permission
  GRANT_RESULT=$(az rest --method POST \
    --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${SP_ID}/appRoleAssignments" \
    --headers "Content-Type=application/json" \
    --body "{
      \"principalId\": \"${SP_ID}\",
      \"resourceId\": \"${MSGRAPH_SP_ID}\",
      \"appRoleId\": \"${PERM_ID}\"
    }" 2>&1)
  
  if echo "${GRANT_RESULT}" | grep -q "error\|Error\|Forbidden\|Insufficient"; then
    echo "      ⚠️  Failed to consent ${PERM_NAME}"
    return 1
  else
    echo "      ✅ ${PERM_NAME} consented"
    return 0
  fi
}

# Grant consent for each permission
CONSENT_FAILED=0
grant_permission "${USER_READ_ALL_ID}" "User.Read.All" || CONSENT_FAILED=1
grant_permission "${DIRECTORY_READ_ALL_ID}" "Directory.Read.All" || CONSENT_FAILED=1
grant_permission "${GROUPMEMBER_READ_ALL_ID}" "GroupMember.Read.All" || CONSENT_FAILED=1
grant_permission "${AUDITLOG_READ_ALL_ID}" "AuditLog.Read.All" || CONSENT_FAILED=1

echo ""
if [[ ${CONSENT_FAILED} -eq 1 ]]; then
  echo "   ⚠️  WARNING: Some permissions failed to get admin consent"
  echo "   This requires one of: Global Administrator, Privileged Role Administrator, or Cloud Application Administrator"
  echo ""
  echo "   MANUAL ACTION REQUIRED - Click this link to grant consent:"
  CONSENT_NEEDED=true
else
  echo "   ✅ All permissions consented successfully"
  echo ""
  echo "   To review or manually grant consent, visit:"
  CONSENT_NEEDED=false
fi

echo "   https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/CallAnAPI/appId/${APP_ID}"
echo ""

echo ">> Microsoft Graph API permissions configured."

# ========= Create Client Secret (idempotent) =========
echo ">> Checking for existing client secrets..."

# Check if a secret already exists
EXISTING_SECRETS=$(az ad app credential list --id "${APP_ID}" --query '[].displayName' -o tsv 2>/dev/null || true)

if echo "${EXISTING_SECRETS}" | grep -q "SecureOS-Access-Secret"; then
  echo ">> Client secret already exists - skipping creation"
  echo "   ⚠️  Note: The existing secret value cannot be retrieved"
  echo "   If you need a new secret, manually delete the old one first or rotate via Azure Portal"
  CLIENT_SECRET="<EXISTING_SECRET_NOT_RETRIEVABLE>"
  SECRET_END_DATE="<SEE_AZURE_PORTAL>"
else
  echo ">> Creating new client secret..."
  
  # Generate a client secret valid for specified years
  SECRET_END_DATE=$(date -u -v+${SECRET_VALIDITY_YEARS}y +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "+${SECRET_VALIDITY_YEARS} years" +"%Y-%m-%dT%H:%M:%SZ")
  
  SECRET_OUTPUT=$(az ad app credential reset \
    --id "${APP_ID}" \
    --append \
    --display-name "SecureOS-Access-Secret" \
    --end-date "${SECRET_END_DATE}" \
    --query '{secret:password, secretId:keyId}' \
    -o json)
  
  CLIENT_SECRET=$(echo "${SECRET_OUTPUT}" | jq -r '.secret')
  SECRET_ID=$(echo "${SECRET_OUTPUT}" | jq -r '.secretId')
  
  echo ">> Client secret created successfully (valid for ${SECRET_VALIDITY_YEARS} years)"
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
  echo "Client Secrets:"
  az ad app credential list --id "${APP_ID}" --query '[].{DisplayName:displayName, KeyId:keyId, EndDate:endDateTime}' -o table
  echo ""
  echo "API Permissions:"
  az ad app permission list --id "${APP_ID}" -o table
fi

# ========= Success output =========
echo ""
echo "=========================================="
echo "SUCCESS ✅"
echo "=========================================="
echo ""
echo "Azure onboarding completed successfully!"
echo ""

if [[ "${CLIENT_SECRET}" == "<EXISTING_SECRET_NOT_RETRIEVABLE>" ]]; then
  echo "⚠️  IMPORTANT: App Registration already exists"
  echo ""
  echo "Configuration values (provide to SecureOS):"
  echo ""
  echo "AZURE_TENANT_ID=${TENANT_ID}"
  echo "AZURE_SUBSCRIPTION_ID=${SUBSCRIPTION_ID}"
  echo "AZURE_CLIENT_ID=${APP_ID}"
  echo "AZURE_CLIENT_SECRET=<USE_EXISTING_SECRET>"
  echo ""
  echo "Note: The existing client secret cannot be retrieved."
  echo "If you lost it, manually rotate the secret in Azure Portal."
else
  echo "⚠️  IMPORTANT: Please provide these credentials to SecureOS securely:"
  echo ""
  echo "AZURE_TENANT_ID=${TENANT_ID}"
  echo "AZURE_SUBSCRIPTION_ID=${SUBSCRIPTION_ID}"
  echo "AZURE_CLIENT_ID=${APP_ID}"
  echo "AZURE_CLIENT_SECRET=${CLIENT_SECRET}"
  echo ""
fi
echo "=========================================="
echo ""
echo "Configuration Summary:"
echo "  Subscription Name:    ${SUBSCRIPTION_NAME}"
echo "  App Registration:     ${APP_REG_NAME}"
echo "  Service Principal ID: ${SP_OBJECT_ID}"
echo "  Secret Valid Until:   ${SECRET_END_DATE}"
echo ""
echo "Roles Assigned:"
echo "  - Reader (subscription-level)"
echo "  - Security Reader (subscription-level)"
echo "  - Log Analytics Reader (subscription-level)"
echo ""
echo "API Permissions:"
echo "  - User.Read.All (Microsoft Graph)"
echo "  - Directory.Read.All (Microsoft Graph)"
echo "  - GroupMember.Read.All (Microsoft Graph)"
echo "  - AuditLog.Read.All (Microsoft Graph)"
echo ""
echo "⚠️  SECURITY NOTES:"
echo "  - Store the CLIENT_SECRET securely (it won't be displayed again)"
echo "  - The secret is valid for ${SECRET_VALIDITY_YEARS} years"
echo "  - You can rotate the secret anytime via Azure Portal"
echo ""

if [[ "${CONSENT_NEEDED:-false}" == "true" ]]; then
  echo "⚠️  ACTION REQUIRED: Admin consent for API permissions is pending!"
  echo ""
  echo "The app will NOT work until admin consent is granted."
  echo ""
  echo "Click here to grant consent:"
  echo "https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/CallAnAPI/appId/${APP_ID}"
  echo ""
fi

