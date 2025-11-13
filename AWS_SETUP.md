# AWS Setup Instructions for SecureOS Team

This document describes the AWS infrastructure setup required to support Azure evidence collection via Federated Identity. This is **internal documentation for the SecureOS engineering team** - customers do not need to perform these steps.

## Overview

To allow our AWS-based infrastructure to access customer Azure subscriptions, we need to:
1. Create an IAM role that can assume Azure identities via federated credentials
2. Configure the trust policy to accept Azure AD tokens
3. Use the Azure SDK in our AWS workloads to obtain Azure access tokens

## Prerequisites

- AWS Account: `294393683475`
- Permissions to create IAM roles and policies

## AWS IAM Role Setup

### 1. Create IAM Role: SecureOSAzureCollectorRole

Create an IAM role with the following trust policy that accepts Azure AD federated tokens:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::294393683475:oidc-provider/sts.amazonaws.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "sts.amazonaws.com:aud": "api://AzureADTokenExchange"
        }
      }
    }
  ]
}
```

### 2. OIDC Provider Setup

**Important**: Azure uses AWS STS as the issuer for federated credentials from Azure to AWS. The customer's Azure federated credential will be configured with:
- **Issuer**: `https://sts.amazonaws.com`
- **Subject**: `arn:aws:sts::294393683475:assumed-role/SecureOSAzureCollectorRole/*`
- **Audience**: `api://AzureADTokenExchange`

Ensure the OIDC provider is created in IAM:

```bash
aws iam create-open-id-connect-provider \
  --url https://sts.amazonaws.com \
  --client-id-list "api://AzureADTokenExchange" \
  --thumbprint-list "1234567890abcdef1234567890abcdef12345678"
```

**Note**: The thumbprint should be verified against the actual AWS STS OIDC endpoint.

### 3. IAM Policy for Azure Operations

Attach an inline policy to `SecureOSAzureCollectorRole` that grants necessary AWS permissions (if any AWS resources are accessed during collection):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "sts:AssumeRoleWithWebIdentity",
        "sts:GetCallerIdentity"
      ],
      "Resource": "*"
    }
  ]
}
```

## Obtaining Azure Access Tokens from AWS

Once a customer runs the setup script, our AWS role can obtain Azure access tokens using the Azure SDK or REST API.

### Method 1: Azure SDK (Recommended)

Using Azure SDK for Python:

```python
from azure.identity import ClientAssertionCredential
import boto3
import json

# Customer's Azure details (obtained after they run setup script)
TENANT_ID = "customer-tenant-id"
CLIENT_ID = "customer-app-client-id"  # From App Registration
AZURE_SCOPE = "https://management.azure.com/.default"

def get_aws_session_token():
    """Get AWS session token for the assumed role"""
    sts = boto3.client('sts')
    
    # When running in AWS with the SecureOSAzureCollectorRole
    identity = sts.get_caller_identity()
    session_name = identity['Arn'].split('/')[-1]
    
    # Get session token
    response = sts.assume_role(
        RoleArn=f"arn:aws:sts::294393683475:assumed-role/SecureOSAzureCollectorRole/{session_name}",
        RoleSessionName=session_name
    )
    
    return response['Credentials']

def get_azure_token():
    """Exchange AWS credentials for Azure access token"""
    aws_creds = get_aws_session_token()
    
    # Create assertion JWT using AWS session token
    # Azure expects the AWS session token as the client assertion
    def token_provider():
        return aws_creds['SessionToken']
    
    credential = ClientAssertionCredential(
        tenant_id=TENANT_ID,
        client_id=CLIENT_ID,
        func=token_provider
    )
    
    token = credential.get_token(AZURE_SCOPE)
    return token.token

# Use the token with Azure SDK
from azure.mgmt.resource import ResourceManagementClient

token = get_azure_token()
subscription_id = "customer-subscription-id"

resource_client = ResourceManagementClient(
    credential=credential,
    subscription_id=subscription_id
)

# Now you can make Azure API calls
for resource_group in resource_client.resource_groups.list():
    print(resource_group.name)
```

### Method 2: Direct REST API

```bash
# Step 1: Assume AWS Role
aws sts assume-role \
  --role-arn arn:aws:sts::294393683475:role/SecureOSAzureCollectorRole \
  --role-session-name azure-collector-session

# Step 2: Exchange AWS session token for Azure token
curl -X POST "https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "client_id=${CLIENT_ID}" \
  -d "scope=https://management.azure.com/.default" \
  -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  -d "client_assertion=${AWS_SESSION_TOKEN}" \
  -d "grant_type=client_credentials"

# Step 3: Use Azure access token
curl -X GET "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourcegroups?api-version=2021-04-01" \
  -H "Authorization: Bearer ${AZURE_ACCESS_TOKEN}"
```

## Customer Information Required

After a customer runs the setup script, collect the following information from them:

1. **Tenant ID** - Their Azure AD tenant ID
2. **Subscription ID** - The Azure subscription ID they granted access to
3. **Application (Client) ID** - The App Registration client ID (displayed by the script)

Store this information securely in our customer database/configuration management system.

## Testing the Integration

### Test Script

```bash
#!/bin/bash
# test-azure-access.sh

TENANT_ID="customer-tenant-id"
CLIENT_ID="customer-client-id"
SUBSCRIPTION_ID="customer-subscription-id"

# Assume our AWS role
ROLE_ARN="arn:aws:sts::294393683475:role/SecureOSAzureCollectorRole"
ROLE_CREDS=$(aws sts assume-role --role-arn $ROLE_ARN --role-session-name test-session --output json)

export AWS_ACCESS_KEY_ID=$(echo $ROLE_CREDS | jq -r '.Credentials.AccessKeyId')
export AWS_SECRET_ACCESS_KEY=$(echo $ROLE_CREDS | jq -r '.Credentials.SecretAccessKey')
export AWS_SESSION_TOKEN=$(echo $ROLE_CREDS | jq -r '.Credentials.SessionToken')

# Get Azure token (simplified - actual implementation needs proper JWT assertion)
# Use Azure SDK in production code

# Test Azure API access
curl -X GET \
  "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resources?api-version=2021-04-01" \
  -H "Authorization: Bearer ${AZURE_ACCESS_TOKEN}"
```

## Security Best Practices

1. **Rotate nothing** - No secrets to rotate! Federated identity uses cryptographic validation
2. **Monitor AWS CloudTrail** - Track `AssumeRoleWithWebIdentity` calls for our role
3. **Monitor Azure Activity Logs** - Track API calls made by our Service Principal
4. **Implement rate limiting** - Avoid excessive API calls to customer Azure subscriptions
5. **Store customer configuration securely** - Tenant ID, Client ID, and Subscription ID should be encrypted at rest

## Monitoring and Logging

### AWS Side
- CloudTrail logs for `AssumeRoleWithWebIdentity` on `SecureOSAzureCollectorRole`
- CloudWatch metrics for role assumption failures

### Azure Side (Customer's Azure)
- Azure Activity Logs show all API calls made by our Service Principal
- Customers can see our access in their Azure AD sign-in logs

## Troubleshooting

### Common Issues

**Error: "Access denied when assuming role"**
- Verify the trust policy includes the correct OIDC provider
- Check that the audience matches: `api://AzureADTokenExchange`

**Error: "Invalid client assertion"**
- Ensure the AWS session token format is correct
- Verify the subject claim matches the expected ARN pattern

**Error: "Insufficient privileges" from Azure**
- Customer may have modified role assignments
- Ask customer to re-run the setup script

## Deployment Checklist

- [ ] IAM role `SecureOSAzureCollectorRole` created in account `294393683475`
- [ ] Trust policy configured for Azure AD federation
- [ ] OIDC provider for AWS STS created
- [ ] IAM policies attached for necessary AWS permissions
- [ ] Azure SDK/API client code tested with sample customer
- [ ] Monitoring and alerting configured
- [ ] Customer onboarding documentation updated
- [ ] Support team trained on troubleshooting federated access

## Additional Resources

- [Azure Federated Identity Documentation](https://learn.microsoft.com/en-us/azure/active-directory/develop/workload-identity-federation)
- [AWS IAM OIDC Federation](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_create_oidc.html)
- [Azure Management REST API Reference](https://learn.microsoft.com/en-us/rest/api/azure/)

## Support Contacts

- **AWS Infrastructure**: devops@secureos.com
- **Azure Integration**: engineering@secureos.com
- **Customer Success**: success@secureos.com

