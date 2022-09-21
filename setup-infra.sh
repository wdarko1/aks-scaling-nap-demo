#!/bin/bash

# Parameters
LOCATION=eastus

CLUSTER_NAME=kedavpademo
CLUSTER_RG=kedavpademo-rg

ACR_NAME=kedavpademoacr
ACR_RG=kedavpademo-rg

KV_NAME=kedavpademokv
KV_RG=kedavpademo-rg
CERTIFICATE_NAME=kedavpademo-wild

AZUREDNS_NAME=demo.azure.sabbour.me
AZUREDNS_RG=kedavpademo-rg

AZURE_TENANT_ID=$(az account show --query tenantId -o tsv)
AZURE_SUBSCRIPTION_ID=$(az account show --query id -o tsv)

# Make sure the KEDA Preview feature is registered
echo "Registering the required providers and features"
az extension add --upgrade --name aks-preview
az feature register --name AKS-KedaPreview --namespace Microsoft.ContainerService
az provider register --namespace Microsoft.ContainerService
az provider register --namespace Microsoft.ContainerInstance


# Create resource group
echo "Creating resource group ${CLUSTER_RG} in ${LOCATION}"
az group create -n ${CLUSTER_RG} -l ${LOCATION}

# Create Azure DNS Zone
echo "Creating Azure DNS zone ${AZUREDNS_NAME}"
az network dns zone create -n ${AZUREDNS_NAME} -g ${AZUREDNS_RG}
AZUREDNS_RESOURCEID=$(az network dns zone show -n ${AZUREDNS_NAME} -g ${AZUREDNS_RG} --query id -o tsv)

# Create an Azure Key Vault
echo "Creating Azure Key Vault ${KV_NAME}"
az keyvault create -n ${KV_NAME} -g ${KV_RG}

# Create a self signed certificate on Azure Key Vault using the policy template
echo "Creating a self-signed certificate on the Key Vault"
sed "s/DOMAIN/${AZUREDNS_NAME}/" kv_cert_policy_template.json > ${CERTIFICATE_NAME}_kv_policy.json
az keyvault certificate create --vault-name ${KV_NAME} -n ${CERTIFICATE_NAME} -p @${CERTIFICATE_NAME}_kv_policy.json

# Create Azure Container Registry
echo "Creating an Azure Container Registry ${ACR_NAME}"
az acr create -n ${ACR_NAME} -g ${ACR_RG} -l ${LOCATION} --sku Basic

# Create AKS cluster attached to the registry and activate Web App Routing, Key Vault CSI, OSM, Monitoring
echo "Creating an Azure Kubernetes Service cluster with add-ons enabled"
az aks create -n ${CLUSTER_NAME} -g ${CLUSTER_RG} --node-count 3 --generate-ssh-keys \
--enable-addons azure-keyvault-secrets-provider,open-service-mesh,web_application_routing, monitoring, virtual-node \
--enable-managed-identity \
--enable-msi-auth-for-monitoring \
--enable-secret-rotation \
--enable-keda \
--attach-acr ${ACR_NAME}

# Update the Web App Routing add-on to use Azure DNS
echo "Updating the Web Application Routing add-on to use the Azure DNS zone"
az aks addon update -n ${CLUSTER_NAME} -g ${CLUSTER_RG} \
--addon web_application_routing \
--dns-zone-resource-id=${AZUREDNS_RESOURCEID}

# Retrieve the user managed identity object ID for the Web App Routing add-on
echo "Retrieving the managed identity for the Web Application Routing add-on"
CLUSTER_RESOURCE_ID=$(az aks show -n ${CLUSTER_NAME} -g ${CLUSTER_RG} --query id -o tsv)
SUBSCRIPTION_ID=$(awk '{ sub(/.*subscriptions\//, ""); sub(/\/resourcegroups.*/, ""); print }' <<< "$CLUSTER_RESOURCE_ID")
MANAGEDIDENTITYNAME="webapprouting-${CLUSTER_NAME}"
NODERESOURCEGROUP=$(az aks show -n ${CLUSTER_NAME} -g ${CLUSTER_RG} --query nodeResourceGroup -o tsv)
USERMANAGEDIDENTITY_RESOURCEID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${NODERESOURCEGROUP}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/${MANAGEDIDENTITYNAME}"
MANAGEDIDENTITY_OBJECTID=$(az resource show --id $USERMANAGEDIDENTITY_RESOURCEID --query "properties.principalId" -o tsv | tr -d '[:space:]')

# Grant the Web App Routing add-on certificate read access on the Key Vault
echo "Granting the We Application Routing add-on certificate read access on the Key Vault"
az keyvault set-policy --name $KV_NAME --object-id $MANAGEDIDENTITY_OBJECTID --secret-permissions get --certificate-permissions get

# Retrieve AKS cluster credentials
echo "Retrieving the Azure Kubernetes Service cluster credentials"
az aks get-credentials -n ${CLUSTER_NAME} -g ${CLUSTER_RG}

# Add the Keda Core Helm repo
echo "Adding the kedacore Helm repo"
helm repo add kedacore https://kedacore.github.io/charts
helm repo update

# Install the KEDA HTTP Add-on into kube-system
echo "Installing the KEDA HTTP add-on into kube-system"
helm install http-add-on kedacore/keda-add-ons-http --namespace kube-system