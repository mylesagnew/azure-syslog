#!/usr/bin/env bash
# Sourced inside an AzureCLI@2 step (addSpnToEnvironment: true). Points Terraform's
# azurerm provider AND backend at the service connection with OIDC, so they
# request and refresh their own tokens - no client secret, nothing stored.
#
# AzureCLI@2 exposes the connection ID as AZURESUBSCRIPTION_SERVICE_CONNECTION_ID and,
# with addSpnToEnvironment, servicePrincipalId / tenantId. SYSTEM_ACCESSTOKEN must be
# mapped into the step's env; SYSTEM_OIDCREQUESTURI is predefined by Azure DevOps.
: "${AZURESUBSCRIPTION_SERVICE_CONNECTION_ID:?run inside an AzureCLI@2 task}"
: "${SYSTEM_ACCESSTOKEN:?map SYSTEM_ACCESSTOKEN: \$(System.AccessToken) in the step env}"

export ARM_USE_OIDC=true
export ARM_USE_AZUREAD=true
export ARM_CLIENT_ID="${servicePrincipalId:-${ARM_CLIENT_ID:-}}"
export ARM_TENANT_ID="${tenantId:-${ARM_TENANT_ID:-}}"
export ARM_SUBSCRIPTION_ID="${ARM_SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}"
# The provider documents ARM_ADO_PIPELINE_SERVICE_CONNECTION_ID; older docs and the
# backend page also use the OIDC_AZURE_SERVICE_CONNECTION_ID spelling - set both.
export ARM_ADO_PIPELINE_SERVICE_CONNECTION_ID="$AZURESUBSCRIPTION_SERVICE_CONNECTION_ID"
export ARM_OIDC_AZURE_SERVICE_CONNECTION_ID="$AZURESUBSCRIPTION_SERVICE_CONNECTION_ID"
export ARM_OIDC_REQUEST_TOKEN="$SYSTEM_ACCESSTOKEN"
export ARM_OIDC_REQUEST_URL="${SYSTEM_OIDCREQUESTURI:-}"
# Never let a static token or secret take precedence over the refreshable flow.
unset ARM_CLIENT_SECRET ARM_OIDC_TOKEN ARM_OIDC_TOKEN_FILE_PATH idToken servicePrincipalKey 2>/dev/null || true

export TF_VAR_admin_ssh_public_key="${ADMIN_SSH_PUBLIC_KEY:?ADMIN_SSH_PUBLIC_KEY missing from the variable group}"
echo "OIDC: client ${ARM_CLIENT_ID} tenant ${ARM_TENANT_ID} subscription ${ARM_SUBSCRIPTION_ID} via service connection ${AZURESUBSCRIPTION_SERVICE_CONNECTION_ID}"
