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
--node-vm-size Standard_DS2_v2 \
--kubernetes-version 1.24.6

#echo "Enabling Prometheus metric collection using Azure Monitor"
#az aks update --enable-azuremonitormetrics -n ${CLUSTER_NAME} -g ${CLUSTER_RG}

# Retrieve AKS cluster credentials
echo "Retrieving the Azure Kubernetes Service cluster credentials"
az aks get-credentials -n ${CLUSTER_NAME} -g ${CLUSTER_RG}

# Add the nginx Helm repo
echo "Adding the nginx Helm repo"
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

# Install nginx
echo "Installing nginx into kube-system namespace"
helm install ingress-nginx ingress-nginx --repo https://kubernetes.github.io/ingress-nginx --namespace kube-system
sleep 10

# Add the Keda Core Helm repo
echo "Adding the kedacore Helm repo"
helm repo add kedacore https://kedacore.github.io/charts
helm repo update

# Install the KEDA HTTP Add-on
echo "Installing the KEDA HTTP add-on into kube-system namespace along with the KEDA add-on"
helm install http-add-on kedacore/keda-add-ons-http --namespace kube-system
sleep 10

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
echo "|                DEPLOYING THE APPLICATION             |"
echo "========================================================"
echo ""
kubectl create ns serverloader
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
echo "curl -k http://${SERVICE_IP}/stats"
echo ""
echo ""
echo "========================================================"
echo "|                   GENERATE LOAD                      |"
echo "========================================================"
echo ""
echo "hey -n 200000 -c 500 http://${SERVICE_IP}/workout"

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

