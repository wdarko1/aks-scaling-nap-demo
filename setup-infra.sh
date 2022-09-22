#!/bin/bash

# Parameters
LOCATION=eastus

CLUSTER_NAME=contososcaling
CLUSTER_RG=contososcaling-rg

ACR_NAME=contososcalingacr
ACR_RG=${CLUSTER_RG}

KV_NAME=contososcalingkv
KV_RG=${CLUSTER_RG}
CERTIFICATE_NAME=contososcaling-wild

AZUREDNS_NAME=demo.azure.sabbour.me
AZUREDNS_RG=${CLUSTER_RG}

VNET_NAME=contososcalingvnet
VNET_RG=${CLUSTER_RG}

# Make sure the features are registered
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

# Create a Virtual Network since Virtual Nodes requires custom subnets
echo "Creating a Virtual Network since Virtual Nodes requires custom subnets ${VNET_NAME}"
az network vnet create -n ${VNET_NAME} -g ${VNET_RG} -l ${LOCATION} \
--address-prefixes 10.0.0.0/8 \
--subnet-name aks-subnet \
--subnet-prefix 10.240.0.0/16
AKSVNET_SUBNETID=$(az network vnet subnet show --name aks-subnet --vnet-name ${VNET_NAME} -g ${VNET_RG}  --query id -o tsv)

# Create a subnet for the virtual nodes
echo "Creating a subnet for the virtual nodes"
az network vnet subnet create -n vn-subnet -g ${VNET_RG} \
--vnet-name ${VNET_NAME} \
--address-prefixes 10.241.0.0/16 

# Create AKS cluster with the required add-ons and configuration
echo "Creating an Azure Kubernetes Service cluster with add-ons enabled"
az aks create -n ${CLUSTER_NAME} -g ${CLUSTER_RG} --generate-ssh-keys \
--enable-addons azure-keyvault-secrets-provider,web_application_routing,monitoring,virtual-node \
--vnet-subnet-id ${AKSVNET_SUBNETID} \
--aci-subnet-name vn-subnet \
--enable-managed-identity \
--enable-msi-auth-for-monitoring \
--enable-secret-rotation \
--enable-keda \
--enable-cluster-autoscaler \
--min-count 3 \
--max-count 6 \
--node-vm-size Standard_DS4_v2 \
--network-plugin azure

# Retrieve the user managed identity object ID for the Web App Routing add-on
echo "Retrieving the managed identity for the Web Application Routing add-on"
CLUSTER_RESOURCE_ID=$(az aks show -n ${CLUSTER_NAME} -g ${CLUSTER_RG} --query id -o tsv)
SUBSCRIPTION_ID=$(awk '{ sub(/.*subscriptions\//, ""); sub(/\/resourcegroups.*/, ""); print }' <<< "$CLUSTER_RESOURCE_ID")
MANAGEDIDENTITYNAME="webapprouting-${CLUSTER_NAME}"
NODERESOURCEGROUP=$(az aks show -n ${CLUSTER_NAME} -g ${CLUSTER_RG} --query nodeResourceGroup -o tsv)
USERMANAGEDIDENTITY_RESOURCEID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${NODERESOURCEGROUP}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/${MANAGEDIDENTITYNAME}"
MANAGEDIDENTITY_OBJECTID=$(az resource show --id $USERMANAGEDIDENTITY_RESOURCEID --query "properties.principalId" -o tsv | tr -d '[:space:]')

# Grant the Web App Routing add-on certificate read access on the Key Vault
echo "Granting the Web Application Routing add-on certificate read access on the Key Vault"
az keyvault set-policy --name ${KV_NAME} --object-id  ${MANAGEDIDENTITY_OBJECTID} --secret-permissions get --certificate-permissions get

# Grant the Web App Routing add-on Contributor prmissions on the Azure DNS zone
echo "Granting the Web Application Routing add-on Contributor access on the Azure DNS zone"
az role assignment create --role "DNS Zone Contributor" --assignee ${MANAGEDIDENTITY_OBJECTID} --scope ${AZUREDNS_RESOURCEID}

# Update the Web App Routing add-on to use Azure DNS
echo "Updating the Web Application Routing add-on to use the Azure DNS zone"
az aks addon update -n ${CLUSTER_NAME} -g ${CLUSTER_RG} \
--addon web_application_routing \
--dns-zone-resource-id=${AZUREDNS_RESOURCEID}

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

# Install the Vertical Pod Autoscaler
echo "Installing the Vertical Pod Autoscaler"
./autoscaler/vertical-pod-autoscaler/hack/vpa-up.sh

echo "========================================================"
echo "|            INFRASTRUCTURE SETUP COMPLETED            |"
echo "========================================================"
echo ""
echo "========================================================"
echo "|                DEPLOY THE APPLICATION                |"
echo "========================================================"
echo ""
echo "Run the following commands:"
echo "==========================="
echo "kubectl create ns serverloader"
echo "kubectl ns serverloader"
echo "kubectl apply -f ./manifests/0-basic-vpa-keda"
echo ""
echo "Wait for a few minutes to make sure the deployments are ready."
echo ""
echo "Annotate the ingress with the Key Vault certificate URI by running this command:"
echo "================================================================================"
echo "KEYVAULT_CERTIFICATE_URI=$(az keyvault certificate show --vault-name ${KV_NAME} -n ${CERTIFICATE_NAME} --query "id" --output tsv)"
echo "kubectl annotate ingress/serverloader -n kube-system --overwrite kubernetes.azure.com/tls-cert-keyvault-uri=${KEYVAULT_CERTIFICATE_URI}"
echo ""
echo ""
echo "========================================================"
echo "|                GO UPDATE YOUR DNS ZONE                |"
echo "========================================================"
echo ""
echo "Make sure that your Azure DNS zone has been updated to properly resolve the hostname."
echo ""
echo "========================================================"
echo "|                 TEST THE APPLICATION                 |"
echo "========================================================"
echo ""
echo "To test with DNS zone updated:"
echo "=============================="
echo "curl -k https://serverloader.${AZUREDNS_NAME}/workout"
echo "curl -k https://serverloader.${AZUREDNS_NAME}/stats"
echo ""
echo "otherwise, you will need to expose the 'keda-add-ons-http-interceptor-proxy' service in kube-system via a LoadBalancer and make requests while setting the proper header."
echo ""
echo "========================================================"
echo "|                    GENERATE LOAD                     |"
echo "========================================================"
echo ""
echo "hey -n 200000 -c 200 https://serverloader.${AZUREDNS_NAME}/workout"

#osm namespace add serverloader

