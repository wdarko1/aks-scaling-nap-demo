#!/bin/bash

# Parameters
RANDOMSTRING=$(mktemp --dry-run XXXXX | tr '[:upper:]' '[:lower:]')
PREFIX=vpa

echo -e "Location (default: westus): \c"
read LOCATION
LOCATION="${LOCATION:=westus}"
echo $LOCATION

echo -e "Resource group (default: ${PREFIX}${RANDOMSTRING}-rg): \c"
read CLUSTER_RG
CLUSTER_RG="${CLUSTER_RG:=${PREFIX}${RANDOMSTRING}-rg}"
echo $CLUSTER_RG

echo -e "aksexperiences.azurecr.io admin username (default: aksexperiences): \c"
read ACRUSER
ACRUSER="${ACRUSER:=aksexperiences}"

echo -e "aksexperiences.azurecr.io admin password: \c"
read ACRPASSWORD

CLUSTER_NAME=${PREFIX}${RANDOMSTRING}
VNET_NAME=${PREFIX}${RANDOMSTRING}
VNET_RG=${CLUSTER_RG}
AZURE_SUBSCRIPTION_ID=$(az account show --query id -o tsv)

echo "========================================================"
echo "|            ABOUT TO RUN THE SETUP SCRIPT             |"
echo "========================================================"
echo ""
echo "Will execute against subscription: ${AZURE_SUBSCRIPTION_ID}"
echo "Continue? Type y or Y."
read REPLY
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]
then
    exit
fi


echo "========================================================"
echo "|                    STARTING SETUP                    |"
echo "========================================================"
echo ""


# Make sure the features are registered
START="$(date +%s)"
# Make sure the KEDA Preview feature is registered
echo "Making sure that the features are registered"
az extension add --upgrade --name aks-preview
az feature register --namespace Microsoft.ContainerService --name AKS-KedaPreview
az feature register --namespace Microsoft.ContainerService --name AKS-VPAPreview
az feature register --namespace Microsoft.ContainerService --name AKS-PrometheusAddonPreview
az provider register --namespace Microsoft.ContainerService

# Create resource group
echo "Creating resource group ${CLUSTER_RG} in ${LOCATION}"
az group create -n ${CLUSTER_RG} -l ${LOCATION}

# Create AKS cluster with the required add-ons and configuration
echo "Creating an Azure Kubernetes Service cluster ${CLUSTER_NAME}"
az aks create -n ${CLUSTER_NAME} -g ${CLUSTER_RG} \
--generate-ssh-keys \
--enable-addons monitoring \
--enable-managed-identity \
--enable-msi-auth-for-monitoring \
--enable-keda \
--enable-cluster-autoscaler \
--enable-vpa \
--min-count 3 \
--max-count 8 \
--node-vm-size Standard_DS3_v2 \
--kubernetes-version 1.24.6

# Retrieve the Log Analytics workspace and Azure monitor workspace details
echo "Retrieving the AKS tenant id"
TENANT_ID=$(az aks show -n ${CLUSTER_NAME} -g ${CLUSTER_RG} --query identity.tenantId -o tsv)

# Enable Prometheus metric collection using Azure Monitor
echo "Enabling Prometheus metric collection using Azure Monitor"
az aks update --enable-azuremonitormetrics -n ${CLUSTER_NAME} -g ${CLUSTER_RG}

# Retrieve the Log Analytics workspace and Azure monitor workspace details
echo "Retrieving the Log Analytics workspace resource id"
LOGANALYTICSWORKSPACE_RESOURCE_ID=$(az aks show -n ${CLUSTER_NAME} -g ${CLUSTER_RG} --query addonProfiles.omsagent.config.logAnalyticsWorkspaceResourceID -o tsv)

echo "Retrieving the Log Analytics workspace resource group"
LOGANALYTICSWORKSPACE_RG=$(az resource show --id ${LOGANALYTICSWORKSPACE_RESOURCE_ID} --query "resourceGroup" -o tsv)

echo "Retrieving the Azure Monitor workspace resource id"
AZUREMONITORWORKSPACE_RESOURCE_ID=$(az resource list -g ${LOGANALYTICSWORKSPACE_RG} --resource-type microsoft.monitor/accounts --query "[?starts_with(name,'defaultazuremonitorworkspace') || starts_with(name,'DefaultAzureMonitorWorkspace')].id" -o tsv)

echo "Retrieving the Azure Monitor workspace Prometheus query endpoint"
AZUREMONITOR_PROM_ENDPOINT=$(az resource show --id $AZUREMONITORWORKSPACE_RESOURCE_ID --query "properties.metrics.prometheusQueryEndpoint" -o tsv | sed -e "s/https:\/\///" )

# Retrieve the kubelet identity
echo "Retrieving kubelet identity clientId for cluster ${CLUSTER_NAME}"
KUBELETIDENTITY_CLIENT_ID=$(az aks show -g ${CLUSTER_RG} -n ${CLUSTER_NAME} --query "identityProfile.kubeletidentity.objectId" -o tsv)
AAD_CLIENT_ID=$(az aks show -g ${CLUSTER_RG} -n ${CLUSTER_NAME} --query "identityProfile.kubeletidentity.clientId" -o tsv)

# Assigning the Monitoring Data Reader role
echo "Assigning the Monitoring Data Reader role"
az role assignment create --assignee-object-id ${KUBELETIDENTITY_CLIENT_ID} --assignee-principal-type ServicePrincipal --role b0d8363b-8ddd-447d-831f-62ca05bff136 --scope ${AZUREMONITORWORKSPACE_RESOURCE_ID}

# Retrieve AKS cluster credentials
echo "Retrieving the Azure Kubernetes Service cluster credentials"
az aks get-credentials -n ${CLUSTER_NAME} -g ${CLUSTER_RG}

END="$(date +%s)"
DURATION=$[ ${END} - ${START} ]

echo ""
echo "========================================================"
echo "|                   SETUP COMPLETED                    |"
echo "========================================================"
echo ""
echo "Total time elapsed: $(( DURATION / 60 )) minutes"
echo ""

echo "========================================================"
echo "|               ADD THE IMAGE PULL SECRET              |"
echo "========================================================"
echo ""
kubectl create ns serverloader
kubectl create secret docker-registry aksexperiences-secret \
    --namespace kube-system \
    --docker-server=aksexperiences.azurecr.io \
    --docker-username=${ACRUSER} \
    --docker-password=${ACRPASSWORD}

echo "========================================================"
echo "|           UPDATING PROMETHEUS AUTH CONFIG            |"
echo "========================================================"
echo ""
yq -i "(.spec.template.spec.containers[0].env[] | select(.name == \"AAD_CLIENT_ID\").value) = \"${AAD_CLIENT_ID}\"" manifests/vpa-keda/keda-prom-auth-deployment.yaml
yq -i "(.spec.template.spec.containers[0].env[] | select(.name == \"AAD_TENANT_ID\").value) = \"${TENANT_ID}\"" manifests/vpa-keda/keda-prom-auth-deployment.yaml
yq -i "(.spec.template.spec.containers[0].env[] | select(.name == \"TARGET_HOST\").value) = \"${AZUREMONITOR_PROM_ENDPOINT}\"" manifests/vpa-keda/keda-prom-auth-deployment.yaml


echo "========================================================"
echo "|               DEPLOYING THE APPLICATION              |"
echo "|                 AND PROMETHEUS CONFIG                |"
echo "========================================================"
echo ""
kubectl apply -f ./manifests/vpa-keda

echo ""
echo "========================================================"
echo "|            GETTING THE INGRESS SERVICE IP            |"
echo "========================================================"
echo ""
SERVICE_IP=""
while [ -z $SERVICE_IP ]
do
    echo "..waiting for the service to get an IP"
    SERVICE_IP=$(kubectl get service serverloader --namespace=serverloader -o jsonpath="{.status.loadBalancer.ingress[0].ip}")
    sleep 5
done

echo "========================================================"
echo "|                 TEST THE APPLICATION                 |"
echo "========================================================"
echo ""
echo "=============================="
echo "curl -k http://${SERVICE_IP}/workout"
echo "curl -k http://${SERVICE_IP}/metrics"
echo "curl -k http://${SERVICE_IP}/stats"
echo ""
echo ""
echo "========================================================"
echo "|                   GENERATE LOAD                      |"
echo "========================================================"
echo ""
echo "hey -n 200000 -c 300 http://${SERVICE_IP}/workout"

echo ""
echo "========================================================"
echo "|       REVIEW METRICS IN DIFFERENT TERMINALS          |"
echo "========================================================"
echo ""
echo "watch kubectl top pod --namespace=serverloader"
echo "watch kubectl top node"

echo ""
echo "========================================================"
echo "|               CLEAN UP AFTER YOU ARE DONE            |"
echo "========================================================"
echo ""
echo "Delete the ${CLUSTER_RG} resource group when you are done by running:"
echo "az group delete --name ${CLUSTER_RG}"
echo ""
echo "Have fun! "

