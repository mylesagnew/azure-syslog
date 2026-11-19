output "service_connection_name" {
  value = azuredevops_serviceendpoint_azurerm.this.service_endpoint_name
}

output "service_connection_id" {
  value = azuredevops_serviceendpoint_azurerm.this.id
}

output "pipeline_identity" {
  value = {
    name         = azurerm_user_assigned_identity.pipeline.name
    client_id    = azurerm_user_assigned_identity.pipeline.client_id
    principal_id = azurerm_user_assigned_identity.pipeline.principal_id
  }
}

output "federation" {
  description = "Issuer/subject trusted by the managed identity."
  value = {
    issuer  = azurerm_federated_identity_credential.ado.issuer
    subject = azurerm_federated_identity_credential.ado.subject
  }
}

output "next_steps" {
  value = <<-EOT
    1. Pipelines > Library > Secure files: upload
         syslog-${var.environment}.tfvars       (your ../terraform/terraform.tfvars)
         syslog-${var.environment}-backend.hcl  (your ../terraform/backend.hcl)
       and authorise them for the pipeline.
    2. Pipelines > New pipeline > (this repo) > Existing YAML > /pipelines/azure-pipelines.yml
    3. First run: approve the use of variable group 'azure-syslog-${var.environment}',
       service connection '${local.service_connection_name}' and environment '${local.pipeline_environment_name}'.
  EOT
}
