# Fivetran Hybrid Deployment Agent

Hybrid Deployment from Fivetran enables you to sync data sources using Fivetran while ensuring the data never leaves the secure perimeter of your environment. It provides flexibility in deciding where to host data pipelines, with processing remaining within your network while Fivetran acts as a unified control plane. When you install a hybrid deployment agent within your environment, it communicates outbound with Fivetran. This agent manages the pipeline processing in your network, with configuration and monitoring still performed through the Fivetran dashboard or API.

For more information see the [Hybrid Deployment documentation](https://fivetran.com/docs/core-concepts/architecture/hybrid-deployment)

---

## Using Hybrid Deployment with containers

The following approach can be used to setup the environment. 

You must have a valid agent TOKEN before you can start the agent.  The TOKEN can be obtained when you [create](https://fivetran.com/docs/core-concepts/architecture/hybrid-deployment/setup-guide#createagent) the agent in the Fivetran Dashboard.

> Note: Docker or Podman must be installed and configured, and it’s recommended to run them in rootless mode.

### Step 1: Install and Start the agent

Run the following as a non root user on a x86_64 Linux host with docker or podman configured.  

Use the command below with your TOKEN and selected RUNTIME (docker or podman) to install and start the agent.

```
TOKEN="YOUR_AGENT_TOKEN" RUNTIME=docker bash -c "$(curl -sL https://raw.githubusercontent.com/fivetran/hybrid_deployment/main/install.sh)"
```

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
