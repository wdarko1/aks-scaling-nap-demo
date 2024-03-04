# Azure Kubernetes Service (AKS) scaling demo using Kubernetes Event Driven Autoscaler, Node Auto Provisioning, and Vertical Pod Autoscaler

## Components

1. Node Auto Provisioning (NAP).
1. Kubernetes Event Driven Autoscaling (KEDA) with a Prometheus scaler.
1. Vertical Pod Autoscaler (VPA).
1. Azure Monitor managed service for Prometheus.
1. Azure Managed Grafana.

## Setup

1. Login using `az login`.
1. Make sure `kubectl` is installed.
1. Make sure `yq` is installed (https://github.com/mikefarah/yq/#install).
1. Run `./setup.sh` in a Bash shell, preferably in [Windows Subsystem for Linux (WSL)](https://learn.microsoft.com/en-us/windows/wsl/install).

## Exposed endpoints

1. `/workout`: generates long strings and stores them in memory.
1. `/metrics`: Prometheus metrics.
1. `/stats`: .NET stats.

## Test

1. Run a load test against the `/workout` endpoint. You can use [Azure Load Testing](https://learn.microsoft.com/en-us/azure/load-testing/quickstart-create-and-run-load-test?tabs=portal).
1. Review the Grafana dashboards.
1. Observe KEDA scaling the deployment based on requests per second.
   ```bash
   kubectl get events -n serverloader --field-selector source=keda-operator -w
   ```
1. Observe the deployments scaling in response to KEDA.
   ```bash
   kubectl get event -n serverloader --field-selector source=deployment-controller  -w
   ```
1. Observe VPA changing the requests on the deployment.
   ```bash
   kubectl get events -n serverloader --field-selector source=vpa-updater -w
   ```
1. Observe Node Auto Provisioning adding more nodes to the cluster.
    ```bash
    kubectl get events -n serverloader --field-selector source=karpenter -w
    ```