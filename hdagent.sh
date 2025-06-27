#!/bin/bash
#
#  This script is used to start the Hybrid Deployment agent using docker or podman
#
#  Requirements:
#  - Run this script as a regular user, not root.
#  - The agent token is required in the conf/config.json
#  - Docker is the default runtime, if using podman use "-r podman"
#  - If no runtime specified, detect if docker or podman available
#
#  For more information:
#     https://fivetran.com/docs/core-concepts/architecture/hybrid-deployment
#
#  usage: ./hdagent.sh [-r docker|podman] start|stop|status
#
# set -x
set -e

if [ "$UID" -eq 0 ]; then
  echo "This script should not be run as root. Please run as a regular user."
  exit 1
fi

BASE_DIR=$(pwd)
CONFIG_FILE=conf/config.json
AGENT_IMAGE="us-docker.pkg.dev/prod-eng-fivetran-ldp/public-docker-us/ldp-agent:production"
CONTAINER_NETWORK="fivetran_ldp"
TOKEN=""
CONTROLLER_ID=""
SOCKET=""
RUN_CMD=""
RUNTIME=""
INTERNAL_SOCKET=""
CONTAINER_ENV_TYPE=""

usage() {
    echo -e "Usage: $0 [-r docker|podman] start|stop|status\n"
    exit 1
}


get_token_from_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        grep -o '"token": *"[^"]*"' "$CONFIG_FILE" | sed 's/.*"token": *"\([^"]*\)".*/\1/'
    fi
}

set_environment() {
    # Set the environment depending on docker or podman

    RUN_CMD="$1"

    # ensure command is available and in path
    if ! command -v $RUN_CMD &> /dev/null
    then
        echo "$RUN_CMD is not installed or not in the PATH."
        exit 1
    fi

    if [[ "$1" == "podman" ]]; then
        # podman is used
        CONTAINER_ENV_TYPE="podman"
        INTERNAL_SOCKET="/run/user/1000/podman/podman.sock"
        if [ "$(id -u)" -eq 0 ]; then
            SOCKET="/run/podman/podman.sock"
        else
            SOCKET="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/podman/podman.sock"
        fi
    else
        # docker is used
        CONTAINER_ENV_TYPE="docker"
        INTERNAL_SOCKET="/var/run/docker.sock"
        DOCKER_ROOT=$(docker info --format '{{.DockerRootDir}}')
        if [ "$DOCKER_ROOT" == "$HOME/.local/share/docker" ]; then
            uid=$(id -u)
            SOCKET="/var/run/user/$uid/docker.sock"
        else
            SOCKET="/var/run/docker.sock"
        fi
    fi

    # make sure socket exist
    if [ ! -S $SOCKET ]; then
        echo "Unable to detect socket for $RUN_CMD [$SOCKET]"
        exit 1
    fi

    # get the token from config file
    TOKEN=$(get_token_from_config)
    if [[ ! -n "$TOKEN" ]]; then
        echo "No token found in $CONFIG_FILE"
        exit 1
    fi

    # extract controller id from token and validate
    DECODED_TOKEN=$(printf "%s" "$TOKEN" | base64 -d 2>/dev/null)
    if [[ $? -ne 0 ]]; then
        echo "Invalid token, please supply a valid token"
        exit 1
    fi

    CONTROLLER_ID=$(printf "%s" "$DECODED_TOKEN" | cut -f1 -d:)
    if [[ $? -ne 0 ]]; then
        echo "Invalid controller-id format, please supply valid token"
        exit 1
    fi
}


status_agent() {
    # agent container name will start with controller and label fivetran=ldp is set.
    CONTAINER_ID=$($RUN_CMD ps -a -q -f name="^/?controller" -f label=fivetran=ldp)
    if [[ -z "$CONTAINER_ID" ]]; then
        echo "Agent container not found."
    else
        $RUN_CMD ps -f name="^/?controller" -f label=fivetran=ldp --format "table {{.ID}}\t{{.Names}}\t{{.Status}}"
    fi
}

stop_agent() {
    # agent container name will start with controller and label fivetran=ldp is set.
    CONTAINER_ID=$($RUN_CMD ps -a -q -f name="^/?controller" -f label=fivetran=ldp)
    if [[ -z "$CONTAINER_ID" ]]; then
        echo "Agent container not found, nothing to stop."
    else
        $RUN_CMD ps -f name="^/?controller" -f label=fivetran=ldp --format "table {{.ID}}\t{{.Names}}\t{{.Status}}"
        echo "Stopping agent and cleaning up container"
        $RUN_CMD stop $CONTAINER_ID > /dev/null 2>&1
        $RUN_CMD rm $CONTAINER_ID > /dev/null 2>&1
    fi
}

start_agent() {
    # Remove existing stopped "controller" container if it exists
    EXISTING=$($RUN_CMD ps -a -q -f name="^/?controller$" -f label=fivetran=ldp)
    if [[ -n "$EXISTING" ]]; then
        echo "Removing old stopped container named 'controller'"
        $RUN_CMD rm "$EXISTING"
    fi

    # create the default network if it does not exist
    set +e
    $RUN_CMD network create --driver bridge $CONTAINER_NETWORK > /dev/null 2>&1
    set -e

    # create and run the agent container in background

    $RUN_CMD run \
        -d \
        --restart "on-failure:3" \
        --pull "always" \
        --label fivetran=ldp \
        --label ldp_process_id=default-controller-process-id \
        --label ldp_controller_id=$CONTROLLER_ID \
        --security-opt label=disable \
        --name controller \
        --network $CONTAINER_NETWORK \
        --env HOST_USER_HOME_DIR=$HOME \
        --env CONTAINER_ENV_TYPE=$CONTAINER_ENV_TYPE \
        -v $BASE_DIR/conf:/conf \
        -v $BASE_DIR/logs:/logs \
        -v $SOCKET:$INTERNAL_SOCKET \
        $AGENT_IMAGE -f /conf/config.json

    sleep 3
    $RUN_CMD 
     po
     d--format "table {{.ID}}\t{{.Names}}\t{{.Status}}"
}

restart_existing_agent_if_needed() {
    # Check if a "controller" container exists (stopped or exited)
    CONTAINER_ID=$($RUN_CMD ps -a -q -f name="^/^controller.*$" -f label=fivetran=ldp)

    if [[ -n "$CONTAINER_ID" ]]; then
        STATUS=$($RUN_CMD inspect --format '{{.State.Status}}' $CONTAINER_ID)
        if [[ "$STATUS" == "exited" || "$STATUS" == "created" || "$STATUS" == "stopped" ]]; then
            echo "Reusing existing stopped container: $CONTAINER_ID"
            $RUN_CMD start $CONTAINER_ID
            return
        elif [[ "$STATUS" == "running" ]]; then
            echo "Container $CONTAINER_ID is already running."
            return
        else
            echo "Unexpected container status: $STATUS. Removing and recreating."
            $RUN_CMD rm $CONTAINER_ID
        fi
    fi

    echo "No suitable existing container found. Starting a new one."
    start_agent
}

while getopts "r:h" opt; do
    case "$opt" in
        r)
            if [[ "$OPTARG" == "docker" || "$OPTARG" == "podman" ]]; then
                RUNTIME="$OPTARG"
            else
                echo "Invalid runtime specified. Use 'docker' or 'podman'."
                exit 1
            fi
            ;;
        h)
            usage
            ;;
        *)
            usage
            ;;
    esac
done

shift $((OPTIND - 1))

# Check if an action (start, stop, status) is provided
if [[ $# -ne 1 ]]; then
    usage
fi

ACTION="$1"

# If no runtime specified, try docker first then podman.
if [[ ! -n "$RUNTIME" ]]; then
    if command -v docker &> /dev/null; then
        RUNTIME="docker"
    elif command -v podman &> /dev/null; then
        RUNTIME="podman"
    else
        echo "Unable to detect runtime (docker or podman)."
        exit 1
    fi
    echo "Runtime: $RUNTIME"
fi

set_environment $RUNTIME

# Validate the action
case "$ACTION" in
    start)
        echo "Starting Hybrid Deployment agent using $RUNTIME"
        restart_existing_agent_if_needed
        ;;
    stop)
        echo "Stop Hybrid Deployment agent..."
        stop_agent
        ;;
    status)
        echo "Agent status check..."
        status_agent
        ;;
    *)
        echo "Invalid action: $ACTION"
        usage
        ;;
esac
