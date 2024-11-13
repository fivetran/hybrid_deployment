# Introduction

This helm chart is for deploying the Hybrid Deployment agent.

# Prerequisites

* Kubernetes 1.29 and above
* Up-to-date version of helm
* Cluster with worker nodes sized to run pipeline processing
    * Minimum 2 x vCPU and 4 GB memory required per JOB (pipeline processing)
    
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
 --version 0.1.0
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

