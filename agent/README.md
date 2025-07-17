# Introduction

This helm chart is for deploying the Hybrid Deployment agent.

# Prerequisites

* Kubernetes 1.29 and above
* Up-to-date version of helm
* Cluster with worker nodes sized to run pipeline processing
    * Recommendation: 8 vCPU and 32G memory is good starting point.    
* Namespace into which you want to deploy agent [The default is the `default` namespace]
* Persistent Volume Claim (pvc) available to all worker nodes in the cluster
* NFS based volume recommended (required accessModes as ReadWriteMany)
* The persistent volume capacity should be larger than your dataset
* Cluster should have network access to both source and destination

# Usage

Installation:

```bash
helm upgrade --install hd-agent \
 oci://us-docker.pkg.dev/prod-eng-fivetran-ldp/public-docker-us/helm/hybrid-deployment-agent \
 --create-namespace \
 --namespace default \
 --set config.data_volume_pvc=YOUR_PERSISTENT_VOLUME_CLAIM \
 --set config.token="YOUR_TOKEN_HERE" \
 --set config.namespace=default \
 --version 0.7.0
 ```

> Notes:
> * Replace `YOUR_PERSISTENT_VOLUME_CLAIM` with your Persistent Volume Claim name.
> * Replace `YOUR_TOKEN_HERE` with your agent token (obtained from Fivetran dashboard on agent creation)

To confirm installation review:

```
helm list -a
kubectl get deployments -n <your namespace>
kubectl get pods -n <your namespace>
kubectl logs <agent-pod-name>
```

Uninstall:

```
helm uninstall hd-agent
```

# Agent and Job Resource Usage

## The Hybrid Deployment agent
The Hybrid Deployment agent is lightweight and does not require excessive CPU and Memory.
The default resource allocation for the agent is 2 CPU and 2Gi Memory.  


```yaml
resources:
    requests:
        cpu: 2
        memory: 2Gi
    limits:
        cpu: 2
        memory: 2Gi
```

## The data processing jobs
The pipeline processing Jobs that will be started by the HD Agent to perform the pipeline processing will require more resources than the Agent.
This depends on the connector, however for most 2 CPU and 4Gi memory per POD will be sufficient.
The default resource allocation for these jobs are 2 CPU and 4Gi Memory.

To adjust, you can use these configuration parameters under the `config` section:

- donkey_container_memory_limit
- donkey_container_memory_request
- donkey_container_cpu_limit
- donkey_container_cpu_request

Example, to adjust, you can set values as shown below:

```yaml
config:
  namespace: default
  data_volume_pvc: YOUR_PVC_HERE
  token: YOUR_TOKEN_HERE
  donkey_container_memory_limit: "4Gi"
  donkey_container_memory_request: "4Gi"
  donkey_container_cpu_limit: "2"
  donkey_container_cpu_request: "2"
  ...
  ...
```

You can also adjust values for one specific connector.
This can be done by using the:
-  donkey_container_cpu_limit_integrations_YOUR_CONNECTOR_ID_HERE
-  donkey_container_cpu_request_integrations_YOUR_CONNECTOR_ID_HERE
-  donkey_container_memory_limit_integrations_YOUR_CONNECTOR_ID_HERE
-  donkey_container_memory_request_integrations_YOUR_CONNECTOR_ID_HERE

Example, if you want all jobs to use the default 2 CPU and 4G Memory, but you want connector ID: demo_connector1 to use 4 CPU and 8Gi Memory you can specify:

```yaml
config:
  namespace: default
  data_volume_pvc: YOUR_PVC_HERE
  token: YOUR_TOKEN_HERE
  donkey_container_cpu_limit_integrations_demo_connector1: "4"
  donkey_container_cpu_request_integrations_demo_connector1: "4"
  donkey_container_memory_limit_integrations_demo_connector1: "8Gi"
  donkey_container_memory_request_integrations_demo_connector1: "8Gi"
```

