# Fivetran Hybrid Deployment Agent

Hybrid Deployment from Fivetran enables you to sync data sources using Fivetran while ensuring the data never leaves the secure perimeter of your environment. It provides flexibility in deciding where to host data pipelines, with processing remaining within your network while Fivetran acts as a unified control plane. When you install a hybrid deployment agent within your environment, it communicates outbound with Fivetran. This agent manages the pipeline processing in your network, with configuration and monitoring still performed through the Fivetran dashboard or API.

For more information see the [Hybrid Deployment documentation](https://fivetran.com/docs/core-concepts/architecture/hybrid-deployment)

Hybrid Deployment can be used with:
* Containers (using Docker or Podman)
* Kubernetes

> Note: You must have a valid agent TOKEN before you can start the agent.  The TOKEN can be obtained when you [create](https://fivetran.com/docs/core-concepts/architecture/hybrid-deployment/setup-guide-docker-and-podman#createagent) the agent in the Fivetran Dashboard.

---

## Using Hybrid Deployment with containers

For detail instructions see the [online documentation](https://fivetran.com/docs/core-concepts/architecture/hybrid-deployment/setup-guide-docker-and-podman).

The following approach can be used to setup the environment. 

> Note: Docker or Podman must be installed and configured, and it’s recommended to run them in rootless mode.

<details><summary>Expand for instructions on using containers</summary>

### Step 1: Install and Start the agent

Run the following as a non root user on a x86_64 Linux host with docker or podman configured.  

Use the command below with your TOKEN and selected RUNTIME (docker or podman) to install and start the agent.

```
TOKEN="YOUR_AGENT_TOKEN" RUNTIME=docker bash -c "$(curl -sL https://raw.githubusercontent.com/fivetran/hybrid_deployment/main/install.sh)"
```

#### (Optional) Configure proxy settings for agent please see [documentation](https://fivetran.com/docs/deployment-models/hybrid-deployment/setup-guide-docker-and-podman#optionalconfigureproxysettingsforlocalenvironmentandcontainerruntime)

The `install.sh` script will create the following directory structure under the user home followed by downloading the agent container image and starting the agent.  Directory structure will be as follow:

```
$HOME/fivetran         --> Agent home directory
├── hdagent.sh         --> Helper script to start/stop the agent container
├── conf               --> Config file location
│   └── config.json    --> Default config file
├── data               --> Persistent storage used during data pipeline processing
├── logs               --> Logs location
└── tmp                --> Local temporary storage used during data pipeline processing
```

A default configuration file `config.json` will be created in the `conf/` sub folder with the token specified.
Only the agent TOKEN is a required parameter, [optional parameters](https://fivetran.com/docs/core-concepts/architecture/hybrid-deployment/setup-guide#agentconfigurationparameters) listed in the documentaiton.

The agent container will be started at the end of the install script.
To manage the agent container, you can use the supplied `hdagent.sh` script.

### Step 2: Manage agent container

Use the `hdagent.sh` script to manage the agent container.  
The default runtime will be docker, if using podman use `-r podman`.

Usage:
```
./hdagent.sh [-r docker|podman] start|stop|status
```

### Step 3: Use systemd to manage agent (optional)

This is optional and example of how you can configure a service to start the agent.

To ensure the agent is restarted on system boot, you can make use of systemd.
During the docker or podman run command, you can adjust `--restart "on-failure:3"` to `--restart "always"` and for most this will work fine.  But in podman this may not always work as intended.

To ensure the agent is started as a service, you can do the following:

> Note: the steps below is for podman using rootless.  The systemd will run under the user, not root. 
1. Stop agent first: `./hdagent.sh stop`
2. Create a local user systemd unit file: `~/.config/systemd/user/hdagent.service` and add the following:

```
[Unit]
Description=Fivetran Hybrid Deployment Agent
After=network.target docker.service podman.service
Requires=default.target

[Service]
Type=oneshot
RemainAfterExit=true
WorkingDirectory=%h/fivetran
ExecStart=%h/fivetran/hdagent.sh start
ExecStop=%h/fivetran/hdagent.sh stop
Environment=PATH=/usr/bin:/bin

[Install]
WantedBy=default.target
```

3.  Reload and enable the service

```
systemctl --user daemon-reload
systemctl --user enable hdagent.service 
systemctl --user start hdagent.service
systemctl --user status hdagent.service
```

You can now review if the agent is running with: 
```
podman ps -a
podman logs controller
```

4.  Enable lingering to make sure the services are started at boot time

> Note: $USER is the unix user that will run the agent.

```
sudo loginctl enable-linger $USER
```

To make sure setting was applied run: `loginctl show-user $USER` and review `Linger` value.

</details>


## Using Hybrid Deployment with Kubernetes

Review the requirements and detailed setup guide as outlined in the [online documentation](https://fivetran.com/docs/core-concepts/architecture/hybrid-deployment/setup-guide-kubernetes)

Requirements:
* A Kubernetes environment (1.29 or above)
* A persistent volume claim (PVC) used during pipeline processing of data
* A valid agent token
* Up-to-date helm and kubectl configured to access your cluster

<details><summary>Expand for instructions on installation of agent in Kubernetes</summary>

<details><summary>(Optional) Configure proxy settings for agent</summary>
Add the proxy settings under config section:

```yaml 
config:
    data_volume_pvc: VOL_CLAIM_HERE
    token: YOUR_TOKEN_HERE
    no_proxy: localhost,127.0.0.1
    http_proxy: http://your-proxy:3128
    https_proxy: http://your-proxy:3128
```
More information in [documentation](https://fivetran.com/docs/deployment-models/hybrid-deployment/setup-guide-kubernetes#agentconfigurationparameters)
</details>

<details><summary>(Optional) Configure node affinity to run Hybrid Deployment jobs on specific nodes</summary>
Kubernetes Node Affinity lets you choose which nodes run your Hybrid Deployment jobs (except the agent).
It is more flexible than Node Selector, allowing you to set rules like running most jobs on smaller nodes and specific connectors on larger ones.

> Notes:
> You can use either Node Selector or Node Affinity, but not both at the same time. To enable Node Affinity, set 'kubernetes_node_selector_enable' to false.

Configure Node Affinity rules in values.yaml file:

In the config section of your Helm values.yaml file, set up affinity rules that link connection IDs to specific scheduling rules.
You can assign multiple connections to a rule, and set a default rule for any connections not listed.

```yaml
config:
  namespace: YOUR_NAMESPACE_HERE
  data_volume_pvc: YOUR_PERSISTENT_VOLUME_CLAIM_HERE
  token: YOUR_TOKEN_HERE
  kubernetes_affinity:
    - rule: small
      connectors:
        - demo_connection1
        - demo_connection2
      default: true
    - rule: large
      connectors:
        - demo_connection3
        - demo_connection4

```
Define Node Affinity rules inside config section:

In the affinity_rules section within the config block of your Helm values.yaml file, specify node affinity rules to determine which nodes handle specific connections. Use standard Kubernetes node affinity syntax, such as labeling nodes with HD_SIZE=SMALL or HD_SIZE=LARGE, to assign connections to the appropriate nodes.

```yaml    
config:
  affinity_rules:
    small:
      affinity:
        nodeAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 1
              preference:
                matchExpressions:
                  - key: HD_SIZE
                    operator: In
                    values:
                      - "SMALL"

    large:
      affinity:
        nodeAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 1
              preference:
                matchExpressions:
                  - key: HD_SIZE
                    operator: In
                    values:
                      - "LARGE"
```
More information in [documentation](https://fivetran.com/docs/deployment-models/hybrid-deployment/faq#howdoiusekubernetesnodeaffinitytorunhybriddeploymentjobsonspecificnodes)
</details>

Installation:
```bash
helm upgrade --install hd-agent \
 oci://us-docker.pkg.dev/prod-eng-fivetran-ldp/public-docker-us/helm/hybrid-deployment-agent \
 --create-namespace \
 --namespace fivetran \
 --set config.data_volume_pvc=YOUR_PERSISTENT_VOLUME_CLAIM \
 --set config.token="YOUR_TOKEN_HERE" \
 --set config.namespace=fivetran \
 --version 0.12.0
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

</details>

