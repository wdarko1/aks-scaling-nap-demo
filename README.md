# Azure Kubernetes Service (AKS) scaling demo

## Components

1. Cluster autoscaler
1. Kubernetes Event Driven Autoscaling (KEDA) with a Prometheus scaler
1. Azure Monitor managed service for Prometheus
1. Azure Managed Grafana

## Setup

1. Login using `az login`
1. Make sure `kubectl` is installed
1. Make sure `yq` is installed (https://github.com/mikefarah/yq/#install)
1. Run `./setup.sh` (or `./setup-scn2.sh` for the optimized setup)

## Exposed endpoints

1. `/workout`: generates long strings and stores them in memory
1. `/metrics`: Prometheus metrics
1. `/stats`: .NET stats

## Test

1. Run a load test against the `/workout` endpoint
1. Review the Grafana dashboards
1. Observe KEDA scaling the `serverloader` deployment based on requests per second
1. Observe cluster autoscaler adding more nodes to the cluster