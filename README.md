# SecureOS Azure Evidence Collector Setup

This repository contains a setup script that grants SecureOS read-only access to your Azure subscription for compliance evidence collection. The script uses **Workload Identity Federation** to allow SecureOS's EKS (Kubernetes) workloads to securely access your Azure resources without requiring secrets or keys.

## Overview

The `secureos-azure-collector.sh` script automates the configuration of:

1. **Azure AD App Registration** - Creates an application identity for SecureOS
2. **Service Principal** - Creates the service principal for role assignments
3. **Read-only Roles** - Assigns least-privilege built-in roles for compliance data collection
4. **Federated Identity Credential** - Configures EKS-to-Azure federation (no secrets required)

## Prerequisites

### Required
- **Azure Subscription** - You need Owner or User Access Administrator permissions on the subscription
- **Azure CLI** - Available in Azure Cloud Shell or install locally ([Install Azure CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli))
- **jq** - JSON processor (pre-installed in Azure Cloud Shell)

### Permissions Required
The user running this script must have:
- Permission to create Azure AD App Registrations
- Permission to assign roles at the subscription level (Owner or User Access Administrator)

### ✅ NO AWS Access Required
This script **only requires Azure credentials**. You do NOT need AWS access or credentials.
The script configures your Azure subscription to trust SecureOS's EKS infrastructure.

## Quick Start

### Option 1: Azure Cloud Shell (Recommended)

Open [Azure Cloud Shell](https://shell.azure.com) and run:

```bash
curl -sL https://raw.githubusercontent.com/cloudworks-ai/secureos-azure-setup/main/secureos-azure-collector.sh | bash -s -- --subscription-id <YOUR_SUBSCRIPTION_ID>
```

### Option 2: Local Azure CLI

If you have Azure CLI installed locally:

```bash
# Download and run the script
curl -sL https://raw.githubusercontent.com/cloudworks-ai/secureos-azure-setup/main/secureos-azure-collector.sh -o secureos-azure-collector.sh
chmod +x secureos-azure-collector.sh
./secureos-azure-collector.sh --subscription-id <YOUR_SUBSCRIPTION_ID>
```

### With Verification

To see detailed setup information after completion:

```bash
curl -sL https://raw.githubusercontent.com/cloudworks-ai/secureos-azure-setup/main/secureos-azure-collector.sh | bash -s -- --subscription-id <YOUR_SUBSCRIPTION_ID> --verify
```

## What This Script Does

### Creates Azure Resources

1. **App Registration**: `SecureOS-Collector`
   - An application identity in Azure AD
   - No secrets or certificates are created

2. **Service Principal**
   - The service principal associated with the app registration
   - Used for role-based access control (RBAC)

### Assigns Read-Only Roles

The script assigns the following built-in Azure roles at the subscription scope:

| Role | Purpose |
|------|---------|
| **Reader** | Read-only access to all resources (compute, storage, networking, etc.) |
| **Security Reader** | Read access to security posture and recommendations in Microsoft Defender for Cloud |
| **Log Analytics Reader** | Read access to activity logs and monitoring data |

These roles provide comprehensive read-only access for compliance evidence collection without granting:
- Write, delete, or modify permissions
- Access to secrets or keys
- Access to data inside storage accounts or databases

### Configures Federated Identity

Creates a federated identity credential that allows **SecureOS's** EKS workloads to obtain Azure access tokens:

- **EKS Cluster**: cloudworks-eks-cluster-prod (NOT your infrastructure)
- **Namespace**: compliance
- **ServiceAccount**: eso-compliance
- **Subject**: `system:serviceaccount:compliance:eso-compliance`
- **Authentication Method**: EKS OIDC → Azure AD (no secrets)

**Note**: This configures trust for SecureOS's infrastructure to access your Azure resources. You don't need any AWS or EKS resources yourself.

## Usage

### Command Syntax

```bash
./secureos-azure-collector.sh --subscription-id <SUBSCRIPTION_ID> [--verify]
```

### Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `--subscription-id <ID>` | Yes | Azure subscription ID to grant access to |
| `--verify` | No | Display detailed setup information after completion |

### Examples

**Basic setup:**
```bash
./secureos-azure-collector.sh --subscription-id a1b2c3d4-e5f6-7890-abcd-ef1234567890
```

**Setup with verification:**
```bash
./secureos-azure-collector.sh --subscription-id a1b2c3d4-e5f6-7890-abcd-ef1234567890 --verify
```

## Finding Your Subscription ID

### Via Azure Portal
1. Go to [portal.azure.com](https://portal.azure.com)
2. Search for "Subscriptions"
3. Copy the Subscription ID from the list

### Via Azure CLI
```bash
az account list --output table
```

### Via Azure Cloud Shell
```bash
az account show --query id -o tsv
```

## Verification

After running the script, you'll see a success message with the following values to provide to SecureOS:
- Tenant ID
- Subscription ID
- Client ID (Application ID)
- Federated Credential Name

To verify the setup manually:

### Check App Registration
```bash
az ad app list --display-name "SecureOS-Collector" --output table
```

### Check Role Assignments
```bash
az role assignment list --all --assignee <SERVICE_PRINCIPAL_ID> --output table
```

### Check Federated Credentials
```bash
az ad app federated-credential list --id <APP_ID> --output table
```

## Security Considerations

### What Access is Granted?
- **Read-only access** to resource metadata and configuration
- **No access** to:
  - Data stored in storage accounts, databases, or Key Vault secrets
  - Ability to create, modify, or delete resources
  - Azure AD user data or passwords

### How is Authentication Secured?
- **No secrets or keys** - Uses workload identity federation (OIDC-based trust)
- SecureOS's EKS ServiceAccount must present valid JWT tokens to obtain Azure tokens
- Azure validates the EKS identity before granting access

### Compliance
- All access is logged in Azure Activity Logs
- Role assignments follow least-privilege principles
- Standard Azure governance and conditional access policies apply

## Troubleshooting

### Error: "Not logged in"
```bash
az login
```

### Error: "Insufficient permissions"
- You need Owner or User Access Administrator role on the subscription
- Contact your Azure administrator

### Error: "az: command not found"
- Install Azure CLI: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli
- Or use Azure Cloud Shell: https://shell.azure.com

### Error: "jq: command not found"
- Install jq: https://stedolan.github.io/jq/download/
- Or use Azure Cloud Shell (jq is pre-installed)

### Role assignment warnings
- Some role assignments may show warnings if they already exist (this is normal and safe)
- The script is idempotent - running it multiple times is safe

## Removing Access

To revoke SecureOS's access to your Azure subscription:

### Option 1: Remove the App Registration (Complete Cleanup)
```bash
# Find the App ID
APP_ID=$(az ad app list --display-name "SecureOS-Collector" --query '[0].appId' -o tsv)

# Delete the App Registration and Service Principal
az ad app delete --id $APP_ID
```

### Option 2: Remove Role Assignments Only (Keep App Registration)
```bash
# Find the Service Principal
SP_ID=$(az ad sp list --display-name "SecureOS-Collector" --query '[0].id' -o tsv)
SUBSCRIPTION_ID="<YOUR_SUBSCRIPTION_ID>"

# Remove each role assignment
az role assignment delete --assignee $SP_ID --role "Reader" --scope /subscriptions/$SUBSCRIPTION_ID
az role assignment delete --assignee $SP_ID --role "Security Reader" --scope /subscriptions/$SUBSCRIPTION_ID
az role assignment delete --assignee $SP_ID --role "Log Analytics Reader" --scope /subscriptions/$SUBSCRIPTION_ID
```

## Support

For issues or questions:
- **Technical Support**: contact@secureos.com
- **Documentation**: https://docs.secureos.com/azure-setup
- **GitHub Issues**: https://github.com/cloudworks-ai/secureos-azure-setup/issues

## License

This script is provided as-is for customers of SecureOS compliance services.
