#!/bin/bash

readinput () {
    # $1: name
    # $2: default value
    local VALUE
    read -p "${1} (default: ${2}): " VALUE
    VALUE="${VALUE:=${2}}"
    echo $VALUE
}

echo ""
echo "========================================================"
echo "|                   SCALE DEMO SETUP                   |"
echo "========================================================"
echo ""

# Disable warnings
az config set core.only_show_errors=yes

AZURE_TENANT_ID=$(az account show --query tenantId -o tsv)
AZURE_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
CURRENT_UPN=$(az account show --query user.name -o tsv) # Get current user's UPN (for role assignments)
CURRENT_OBJECT_ID=$(az ad user show --id ${CURRENT_UPN} --query id -o tsv) # Get current user's Object ID (for role assignments)

# Parameters
PREFIX=kceu24

LOCATION=`readinput "Location" "eastus"`
DNSZONE=`readinput "DNS Zone" "aks.contosonative.io"`
DNSZONE_RESOURCEGROUP=`readinput "DNS Zone Resource Group" "contosonative.io-dns-rg"`

# Use this to override the DNS Zone ID if the DNS zone is in a different subscription than the rest of the resources in this script
# when this is set, the script will not attempt to retrieve the DNS zone ID and will use the provided value
# set to blank in the inputs to use the default behavior
DNSZONE_ID_OVERRIDE=`readinput "DNS Zone ID Override" "/subscriptions/26fe00f8-9173-4872-9134-bb1d2e00343a/resourceGroups/contosonative.io-dns-rg/providers/Microsoft.Network/dnszones/aks.contosonative.io"`
DNSZONE_ID_OVERRIDE=`echo -- ${DNSZONE_ID_OVERRIDE}` # trim spaces

PREFIX=`readinput "Prefix" "${PREFIX}"`
RANDOMSTRING=`readinput "Random string" "$(mktemp --dry-run XXX | tr '[:upper:]' '[:lower:]')"`
IDENTIFIER="${PREFIX}${RANDOMSTRING}"

CLUSTER_RG=`readinput "Resource group" "${IDENTIFIER}-rg"`
CLUSTER_NAME="${IDENTIFIER}"
DEPLOYMENT_NAME="${IDENTIFIER}-deployment"
HOSTNAME="${IDENTIFIER}.${DNSZONE}"

AVAILABLE_K8S_VERSIONS=$(az aks get-versions --location ${LOCATION} --query "sort(values[?isPreview == null][].patchVersions.keys(@)[-1])" -o tsv | tr '\n' ',' | sed 's/,$//')
LATEST_K8S_VERSION=$(az aks get-versions --location ${LOCATION} --query "sort(values[?isPreview == null][].patchVersions.keys(@)[-1])[-1]" -o tsv)
K8S_VERSION=`readinput "Kubernetes version (${AVAILABLE_K8S_VERSIONS})" "${LATEST_K8S_VERSION}"`

echo ""
echo "========================================================"
echo "|               ABOUT TO RUN THE SCRIPT                |"
echo "========================================================"
echo ""
echo "Will execute against subscription: ${AZURE_SUBSCRIPTION_ID}"
echo "To change, terminate the script, run az account set --subscription <subscrption id> and run the script again."
echo "Continue? Type y or Y."
read REPLY
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]
then
    exit
fi

echo ""
echo "========================================================"
echo "|               CONFIGURING PREREQUISITES              |"
echo "========================================================"
echo ""

START="$(date +%s)"
# Make sure the preview features are registered
echo "Making sure that the features are registered"
az extension add --upgrade --name aks-preview
az feature register --namespace "Microsoft.ContainerService" --name "NodeAutoProvisioningPreview" -o none

az provider register --namespace Microsoft.ContainerService -o none

echo ""
echo "========================================================"
echo "|                CREATING RESOURCE GROUP               |"
echo "========================================================"
echo ""

echo "Creating resource group ${CLUSTER_RG} in ${LOCATION}"
az group create -n ${CLUSTER_RG} -l ${LOCATION}

echo ""
echo "========================================================"
echo "|          CREATING AZURE MONITOR WORKSPACE            |"
echo "========================================================"
echo ""

echo "Creating Azure Monitor Workspace"
AZUREMONITORWORKSPACE_RESOURCE_ID=$(az monitor account create -n ${IDENTIFIER}  -g ${CLUSTER_RG}  --query id -o tsv)

echo ""
echo "Retrieving the Azure Monitor managed service for Prometheus query endpoint"
AZUREMONITOR_PROM_ENDPOINT=$(az resource show --id $AZUREMONITORWORKSPACE_RESOURCE_ID --query "properties.metrics.prometheusQueryEndpoint" -o tsv)
echo "Will later update the KEDA ScaledObject with this Prometheus query endpoint ${AZUREMONITOR_PROM_ENDPOINT}"

echo ""
echo "========================================================"
echo "|             CREATING AZURE MANAGED GRAFANA           |"
echo "========================================================"
echo ""

echo "Creating Azure Managed Grafana"
AZUREGRAFANA_ID=$(az grafana create -n ${IDENTIFIER}  -g ${CLUSTER_RG} --skip-role-assignments --query id -o tsv)
AZUREGRAFANA_PRINCIPALID=$(az resource show --id $AZUREGRAFANA_ID --query "identity.principalId" -o tsv)

echo "Granting Grafana Admin role assignment to ${CURRENT_UPN} (${CURRENT_OBJECT_ID})"
az role assignment create --assignee ${CURRENT_OBJECT_ID} --role "Grafana Admin" --scope ${AZUREGRAFANA_ID}

echo "Granting Monitoring Reader role assignment to Grafana on the Azure Monitor workspace"
az role assignment create --assignee ${AZUREGRAFANA_PRINCIPALID} --role "Monitoring Reader" --scope ${AZUREMONITORWORKSPACE_RESOURCE_ID}

echo "Granting Monitoring Reader role assignment to Grafana on the subscription"
az role assignment create --assignee ${AZUREGRAFANA_PRINCIPALID} --role "Monitoring Reader" --scope "/subscriptions/${AZURE_SUBSCRIPTION_ID}"

echo "Sleeping to allow for identity to propagate"
sleep 60

echo ""
echo "========================================================"
echo "|                  CREATING AKS CLUSTER                |"
echo "========================================================"
echo ""
echo "Features: Prometheus and Grafana, Container Insights for Logs, Workload Identity, KEDA, VPA, NAP, Azure Key Vault, Azure CNI Overlay with Cilium, Application Routing"

# Create AKS cluster with the required add-ons and configuration
echo "Creating an Azure Kubernetes Service cluster ${CLUSTER_NAME} with Kubernetes version ${K8S_VERSION}"
az aks create -n ${CLUSTER_NAME} -g ${CLUSTER_RG} \
--enable-azure-monitor-metrics \
--azure-monitor-workspace-resource-id ${AZUREMONITORWORKSPACE_RESOURCE_ID} \
--grafana-resource-id ${AZUREGRAFANA_ID} \
--enable-workload-identity \
--enable-oidc-issuer \
--enable-msi-auth-for-monitoring \
--enable-keda \
--enable-vpa \
--node-provisioning-mode Auto \
--enable-addons azure-keyvault-secrets-provider,monitoring \
--enable-secret-rotation \
--network-dataplane cilium \
--network-plugin azure \
--network-plugin-mode overlay \
--kubernetes-version ${LATEST_K8S_VERSION}

echo "Tainting the system node pool to prevent workloads from running on it"
az aks nodepool update --cluster-name ${CLUSTER_NAME} -g ${CLUSTER_RG} -n nodepool1 -node-taints CriticalAddonsOnly=true:NoSchedule

echo ""
echo "========================================================"
echo "|         CONFIGURE WORKLOAD IDENTITY FOR KEDA         |"
echo "========================================================"
echo ""

# Create a managed identity for KEDA
echo "Creating a managed identity for KEDA"
az identity create -n keda-${CLUSTER_NAME} -g ${CLUSTER_RG}
echo ""
KEDA_UAMI_CLIENTID=$(az identity show -n keda-${CLUSTER_NAME} -g ${CLUSTER_RG} --query clientId -o tsv)
KEDA_UAMI_PRINCIPALID=$(az identity show -n keda-${CLUSTER_NAME} -g ${CLUSTER_RG} --query principalId -o tsv)
echo "Will later update the KEDA TriggerAuthentication to use this client identity ${KEDA_UAMI_CLIENTID}"
echo "Will later update the role assignment to use this principal identity ${KEDA_UAMI_PRINCIPALID}"

# Wait until the provisioning state of the cluster is not updating
echo "Waiting for the cluster to be ready"
while [[ "$(az aks show -n ${CLUSTER_NAME} -g ${CLUSTER_RG} --query 'provisioningState' -o tsv)" == "Updating" ]]; do
    sleep 10
done

echo ""
echo "Sleeping to allow for identity to propagate"
sleep 30

# Create a federated identity credential for KEDA
echo ""
echo "Creating a federated identity credential for KEDA"
AKS_OIDC_ISSUER=$(az aks show -n ${CLUSTER_NAME} -g ${CLUSTER_RG} --query "oidcIssuerProfile.issuerUrl" -o tsv)
az identity federated-credential create --name keda-${CLUSTER_NAME} --identity-name keda-${CLUSTER_NAME} --resource-group ${CLUSTER_RG} --issuer ${AKS_OIDC_ISSUER} --subject system:serviceaccount:kube-system:keda-operator

# Assigning the Monitoring Data Reader role to KEDA's managed identity
echo ""
echo "Assigning the Monitoring Data Reader role to KEDA's managed identity"
az role assignment create --assignee ${KEDA_UAMI_PRINCIPALID} --role "Monitoring Data Reader" --scope ${AZUREMONITORWORKSPACE_RESOURCE_ID}

echo ""
echo "========================================================"
echo "|             CONFIGURE APP ROUTING ADD-ON             |"
echo "========================================================"
echo ""

if [ -z "${DNSZONE_ID_OVERRIDE}" ]; then
  echo "Retrieving the Azure DNS zone ID for ${DNSZONE} in resource group ${DNSZONE_RESOURCEGROUP}"
  AZUREDNS_ZONEID=$(az network dns zone show -n ${DNSZONE} -g ${DNSZONE_RESOURCEGROUP} --query "id" --output tsv)
else
  echo "Using the provided Azure DNS zone ID for ${DNSZONE}"
  AZUREDNS_ZONEID=${DNSZONE_ID_OVERRIDE}
fi

echo "Attaching the zone to the app routing addon and assigning the DNS Zone Contributor permission"
az aks approuting zone add -g ${CLUSTER_RG} -n ${CLUSTER_NAME} --ids="${AZUREDNS_ZONEID}" --attach-zones

echo ""
echo "========================================================"
echo "|                    FINISHING UP                      |"
echo "========================================================"
echo ""

echo "Importing the nginx dashboards into Grafana"
az grafana dashboard import -n ${IDENTIFIER}  -g ${CLUSTER_RG} --definition @./grafana/nginx.json
az grafana dashboard import -n ${IDENTIFIER}  -g ${CLUSTER_RG} --definition @./grafana/request-handling-performance.json
az grafana dashboard create -n ${IDENTIFIER}  -g ${CLUSTER_RG} --definition @./grafana/demo-dashboard.json

# Retrieve Grafana dashboard URL
echo "Retrieving the Grafana dashboard URL"
GRAFANA_URL=$(az grafana show -n ${IDENTIFIER}  -g ${CLUSTER_RG} --query "properties.endpoint" -o tsv)

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
echo "|                  UPDATING MANIFESTS                  |"
echo "========================================================"
echo ""
echo "Updating the manifests/scaledobject.yaml file with Prometheus query endpoint > manifests/generated/scaledobject.yaml "
yq "(.spec.triggers.[] | select(.type == \"prometheus\")).metadata.serverAddress |= \"${AZUREMONITOR_PROM_ENDPOINT}\"" manifests/scaledobject.yaml > manifests/generated/scaledobject.yaml
echo "Updating the manifests/triggerauthentication.yaml file with KEDA client id > manifests/generated/triggerauthentication.yaml"
yq "(.spec.podIdentity.identityId) |= \"${KEDA_UAMI_CLIENTID}\"" manifests/triggerauthentication.yaml > manifests/generated/triggerauthentication.yaml
echo "Updating the manifests/ingress.yaml file with hostname > manifests/generated/ingress.yaml"
yq "(.spec.rules[0]).host |= \"${HOSTNAME}\"" manifests/ingress.yaml > manifests/generated/ingress.yaml

echo ""
echo "========================================================"
echo "|       DEPLOYING THE PROMETHEUS SCRAPING CONFIG       |"
echo "========================================================"
echo ""
kubectl apply -f ./manifests/config/ama-metrics-settings.config.yaml

echo ""
echo "========================================================"
echo "|               DEPLOYING THE APPLICATION              |"
echo "========================================================"
echo ""
kubectl apply -f ./manifests/namespace.yaml
kubectl apply -f ./manifests/deployment.yaml
kubectl apply -f ./manifests/service.yaml
kubectl apply -f ./manifests/pdb.yaml
kubectl apply -f ./manifests/verticalpodautoscaler.yaml
kubectl apply -f ./manifests/generated/ingress.yaml
kubectl apply -f ./manifests/generated/triggerauthentication.yaml
kubectl apply -f ./manifests/generated/scaledobject.yaml

# Force a restart for the keda operator deployment to pick up the new trigger authentication
kubectl rollout restart deployment.apps/keda-operator -n kube-system

echo ""
echo "========================================================"
echo "|                GETTING THE ENDPOINTS                 |"
echo "========================================================"
echo ""
INGRESS_IP=""
echo "Waiting for the ingress to get an IP address"
while [ -z $INGRESS_IP ]
do
    INGRESS_IP=$(kubectl get ingress serverloader --namespace=serverloader -o jsonpath="{.status.loadBalancer.ingress[0].ip}")
    sleep 5
done

# Only show the DNS record creation if the DNS zone ID was not provided
if [ -z "${DNSZONE_ID_OVERRIDE}" ]; then
  echo "Waiting for the A record to be created in the DNS zone"
  while [[ "$(az network dns record-set a list -g ${DNSZONE_RESOURCEGROUP} -z ${DNSZONE} --query "[?name=='${IDENTIFIER}'].provisioningState" -o tsv)" != "Succeeded" ]]; do
      sleep 5
  done
fi

echo ""
echo "========================================================"
echo "|                 TEST THE APPLICATION                 |"
echo "========================================================"
echo ""
echo "curl -k http://${INGRESS_IP}/workout -H \"Host: ${HOSTNAME}\""
echo "curl -k http://${INGRESS_IP}/metrics -H \"Host: ${HOSTNAME}\""
echo "curl -k http://${INGRESS_IP}/stats -H \"Host: ${HOSTNAME}\""
echo ""
echo "curl -k http://${HOSTNAME}/workout"
echo "curl -k http://${HOSTNAME}/metrics"
echo "curl -k http://${HOSTNAME}/stats"
echo ""
echo "Grafana dashboard: ${GRAFANA_URL}"
echo ""
echo ""
echo "========================================================"
echo "|               CLEAN UP AFTER YOU ARE DONE            |"
echo "========================================================"
echo ""
echo "Delete the ${CLUSTER_RG} resource group when you are done by running:"
echo "az group delete --name ${CLUSTER_RG} --no-wait"
echo ""
echo "Delete the ${HOSTNAME} records when you are done by running:"
echo "az network dns record-set a delete -g ${DNSZONE_RESOURCEGROUP} -z ${DNSZONE} -n ${IDENTIFIER}"
echo "az network dns record-set txt delete -g ${DNSZONE_RESOURCEGROUP} -z ${DNSZONE} -n ${IDENTIFIER}"
echo ""
echo "Have fun!"

# Enable warnings
az config set core.only_show_errors=no
