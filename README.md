# Fivetran Hybrid Deployment Agent

Hybrid Deployment from Fivetran enables you to sync data sources using Fivetran while ensuring the data never leaves the secure perimeter of your environment. It provides flexibility in deciding where to host data pipelines, with processing remaining within your network while Fivetran acts as a unified control plane. When you install a hybrid deployment agent within your environment, it communicates outbound with Fivetran. This agent manages the pipeline processing in your network, with configuration and monitoring still performed through the Fivetran dashboard or API.

For more information see the [Hybrid Deployment documentation](https://fivetran.com/docs/core-concepts/architecture/hybrid-deployment)

---

## Using Hybrid Deployment with containers

The following approach can be used to setup the environment. You must have a valid agent TOKEN before you can start the agent.  The Token can be obtained when you create the agent in the Fivetran Dashboard.

> Note: Docker or Podman must already be installed and configured.

### Step 1: Install and Start the agent

Run the following as a non root user on a system with docker or podman configured.  

Use the command below with your TOKEN and selected RUNTIME (docker or podman) to install and start the agent.

```
TOKEN="YOUR_AGENT_TOKEN" RUNTIME=docker bash -c "$(curl -sL https://raw.githubusercontent.com/fivetran/hybrid_deployment/main/install.sh)"
```

The above command will create the following directory structure under the user home directory:

```
./fivetran
├── hdagent.sh         - is a helper script ot start/stop the agent container
├── conf               - config file location
│   └── config.json
├── data               - local persistent storage, used during pipeline data processing
├── logs               - logfile location
└── tmp                - local temporary storage location, used during pipeline data processing
```

A default configuration file `config.json` will be created in the `conf/` sub folder with the token specified.
Only the agent TOKEN is a required parameter, with [optional parameters](https://fivetran.com/docs/core-concepts/architecture/hybrid-deployment) listed in the documentaiton.

The agent container will be started at the end of the install script.
To manage the agent container, you can use the supplied `hdagent.sh` script.

### Step 2: Manage agent container

Use the `hdagent.sh` script to manage the agent container.

Usage:
```
./hdagent.sh [-r docker|podman] start|stop|status
```
