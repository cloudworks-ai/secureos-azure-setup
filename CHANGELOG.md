# Changelog - Azure Onboarding Script

## Migration from AWS Role-Based to EKS-Based Federation

### Date: November 14, 2025

---

## Changes Made

### 1. PRD Updates (`prd`)

#### Added Sections:
- **Section 3.0**: Prerequisites Check - Verifies Azure CLI, jq, login status, and permissions
- **Section 3.7**: Error Handling - Defines behavior for common failure scenarios
- **Section 6**: Required Azure Permissions - Lists specific AD and subscription permissions needed
- **Section 7**: Testing Checklist - Comprehensive checklist before release

#### Improved Documentation:
- Formatted input flags table properly (markdown table)
- Added hardcoded constants table with actual values
- Clarified output format with example layout
- Expanded verification section with specific commands
- Fixed command syntax in usage example (added `bash -s --`)

---

### 2. Script Updates (`secureos-azure-collector.sh`)

#### Core Changes:
**From: AWS Role-Based Federation**
- Issuer: `https://sts.amazonaws.com`
- Subject: `arn:aws:sts::294393683475:assumed-role/SecureOSAzureCollectorRole/*`

**To: EKS-Based Federation**
- Issuer: `https://oidc.eks.us-east-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B716D3041E` (placeholder)
- Subject: `system:serviceaccount:secureos:azure-collector`
- Audience: `api://AzureADTokenExchange`

#### Naming Changes:
- App Registration: `SecureOS-Evidence-Collector` → `SecureOS-Collector`
- Federated Credential: `secureos-federation` → `SecureOSFederatedAccess`

#### CLI Changes:
- Flag: `--subscription` → `--subscription-id` (also accepts `--subscription` for backward compatibility)
- Usage example updated in help text

#### Output Changes:
- Enhanced output format with clearer sections
- Added copy-pasteable credentials format:
  ```
  TENANT_ID=xxx
  SUBSCRIPTION_ID=xxx
  CLIENT_ID=xxx
  FEDERATED_CREDENTIAL_NAME=xxx
  ```
- Improved configuration summary

---

### 3. README Updates (`README.md`)

Updated all documentation to reflect EKS-based approach:
- Changed "AWS infrastructure" references to "EKS (Kubernetes) workloads"
- Updated all command examples to use `--subscription-id` flag
- Changed app registration name references throughout
- Updated federated identity section with EKS details
- Updated authentication security section with JWT token information
- Updated removal/cleanup commands with new app name

---

## Key Improvements

### Security
✅ Maintained secretless authentication
✅ Maintained least-privilege access
✅ Three read-only roles assigned: Reader, Security Reader, Log Analytics Reader

### User Experience
✅ Better structured output with clear sections
✅ Copy-pasteable credentials format
✅ Clearer error messages and usage information
✅ Backward compatible flag support

### Documentation
✅ Comprehensive PRD with all requirements documented
✅ Complete prerequisites and permissions section
✅ Testing checklist for validation
✅ Error handling specifications

---

## Migration Notes

### ⚠️ CRITICAL: Update EKS Issuer (SecureOS Team Only)

The script currently contains a placeholder EKS OIDC issuer URL:
```bash
EKS_ISSUER="https://oidc.eks.us-east-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B716D3041E"
```

**Before deployment, SecureOS team must replace this with SecureOS's production EKS OIDC issuer URL.**

This is **SecureOS's own EKS cluster**, not the customer's. Customers do NOT need AWS access.

SecureOS team: Get the correct issuer with:
```bash
aws eks describe-cluster --name secureos-prod --query "cluster.identity.oidc.issuer" --output text
```

### ✅ Customer Experience
- Customers only need Azure credentials (no AWS required)
- Script runs entirely in Azure Cloud Shell
- Zero AWS infrastructure needed from customer side
- SecureOS's EKS workloads will access customer's Azure subscription

### Testing Required
Before releasing to customers, verify:
- [ ] **[SecureOS Team]** Update EKS_ISSUER with actual SecureOS production value
- [ ] Test script in Azure Cloud Shell (customer perspective - Azure only)
- [ ] Confirm NO AWS credentials are required by customer
- [ ] Test idempotency (run twice)
- [ ] Verify all four roles are assigned
- [ ] Verify federated credential is created with correct issuer/subject
- [ ] **[SecureOS Backend]** Test EKS ServiceAccount can obtain Azure tokens
- [ ] Verify no secrets are generated
- [ ] Document for customers: "You only need Azure access, no AWS required"

---

## Files Modified

1. ✅ `prd` - Enhanced PRD with 7 complete sections
2. ✅ `secureos-azure-collector.sh` - Migrated to EKS federation
3. ✅ `README.md` - Updated all documentation
4. 📝 `CHANGELOG.md` - This file (new)

---

## Next Steps

1. **Update EKS Issuer**: Replace placeholder with actual EKS OIDC issuer URL
2. **Test Locally**: Run script in Azure Cloud Shell with test subscription
3. **Verify Federation**: Ensure EKS pods can authenticate to Azure
4. **Update Hosting**: Deploy updated script to `https://secureos.sh/azure/setup.sh`
5. **Customer Communication**: Notify customers of new onboarding method (if needed)

