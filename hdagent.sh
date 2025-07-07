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
#  usage: ./hdagent.sh [-r docker|podman] [-s] start|stop|status
#
# set -x
set -e

if [ "$UID" -eq 0 ]; then
  echo "This script should not be run as root. Please run as a regular user."
  exit 1
fi

MIN_DOCKER_VERSION="20.10.17"
MIN_PODMAN_VERSION="4.5.0"
TIMEOUT=5

BASE_DIR=$(pwd)
SCRIPT_PATH="$(realpath "$0")"
CONFIG_FILE=conf/config.json
AGENT_IMAGE="us-docker.pkg.dev/prod-eng-fivetran-ldp/public-docker-us/ldp-agent:production"
SCRIPT_URL="https://raw.githubusercontent.com/fivetran/hybrid_deployment/main/hdagent.sh"
CONTAINER_NETWORK="fivetran_ldp"
TOKEN=""
CONTROLLER_ID=""
SOCKET=""
STORAGE_DIR=""
RUN_CMD=""
RUNTIME=""
INTERNAL_SOCKET=""
CONTAINER_ENV_TYPE=""
SKIP_CHECKS=""
WARNINGS=()
ERRORS=()

usage() {
    echo -e "Usage: $0 [-r docker|podman] [-s] start|stop|status\n"
    echo -e "  -r: Specify runtime (docker or podman)"
    echo -e "  -s: Skip validation checks on agent start"
    echo ""
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
        if podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null | grep -q 'true'; then
            # podman is running in rootless mode
            SOCKET="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/podman/podman.sock"
            STORAGE_DIR="$HOME/.local/share/containers"
        else
            # podman is running in rootful mode
            SOCKET="/run/podman/podman.sock"
            STORAGE_DIR="/var/lib/containers"
        fi
    else 
        # docker is used
        CONTAINER_ENV_TYPE="docker"
        INTERNAL_SOCKET="/var/run/docker.sock"
        DOCKER_ROOT=$(docker info --format '{{.DockerRootDir}}')
        STORAGE_DIR="$DOCKER_ROOT"
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

validate_script_hash() {
    echo -n "Checking if script is latest version... "

    local current_hash
    local latest_script
    local latest_hash

    # Compute hash of the current script
    if command -v sha256sum &> /dev/null; then
        current_hash=$(sha256sum "$SCRIPT_PATH" | cut -d' ' -f1)
    else
        echo -e "\nUnable to compute hash of the current script\n"
        return
    fi

    # Fetch the latest script
    if command -v curl &> /dev/null; then
        latest_script=$(curl -sf --max-time ${TIMEOUT} --retry 1 "$SCRIPT_URL" 2>/dev/null) || true
    elif command -v wget &> /dev/null; then
        latest_script=$(wget -qO- --timeout=${TIMEOUT} --tries=2 "$SCRIPT_URL" 2>/dev/null) || true
    fi

    # Compute hash of the latest script if retrieved successfully
    if [[ -n "$latest_script" ]]; then
        latest_hash=$(echo "$latest_script" | sha256sum | cut -d' ' -f1)
    else
        echo -e "\nUnable to retrieve the latest script\n"
        return
    fi

    # Compare current hash with latest hash
    if [[ "$current_hash" != "$latest_hash" ]]; then
        echo -e "\n\n** WARNING: This script may be outdated or modified **"
        echo -e "To ensure proper agent functioning, please use the latest script at $SCRIPT_URL\n"
    else
        echo -e "OK\n"
    fi
}

check_container_runtime_version() {
    local min_version
    local version_output
    local version
    local error

    if [[ "$RUN_CMD" == "docker" ]]; then
        min_version="$MIN_DOCKER_VERSION"
    elif [[ "$RUN_CMD" == "podman" ]]; then
        min_version="$MIN_PODMAN_VERSION"
    fi

    version_output=$("$RUN_CMD" --version 2>&1)
    if [[ $? -ne 0 ]]; then
        ERRORS+=("Failed to execute '$RUN_CMD --version'. $RUN_CMD may not be installed or not functioning properly")
        return
    fi

    version=$(echo "$version_output" | awk '{print $3}' | sed 's/,$//')
    if [[ -z "$version" ]]; then
        WARNINGS+=("Unable to determine $RUN_CMD version")
        return
    fi

    if [[ "$(printf '%s\n' "$min_version" "$version" | sort -V | head -n1)" != "$min_version" ]]; then
        ERRORS+=("$RUN_CMD version $version does not meet the minimum requirement of $min_version")
    fi
}

check_resources() {
    local cpu_count=$(grep -c "^processor" /proc/cpuinfo)
    local total_mem_kb=$(grep "MemTotal" /proc/meminfo | awk '{print $2}')

    if [[ $cpu_count -lt 8 ]]; then
        WARNINGS+=("CPU count is below the recommended minimum of 8")
    fi

    if [[ $total_mem_kb -lt 33554432 ]]; then  # 32*1024*1024
        WARNINGS+=("RAM is below the recommended minimum of 32GB")
    fi
}

check_container_storage_space() {
    local storage_space_mb

    if [ ! -d "$STORAGE_DIR" ]; then
        WARNINGS+=("Container storage directory not found at $STORAGE_DIR")
        return
    fi

    storage_space_mb=$(df -m "$STORAGE_DIR" 2>/dev/null | awk 'NR==2 {print $2}')
    if [ $? -ne 0 ] || [ -z "$storage_space_mb" ]; then
        WARNINGS+=("Unable to determine disk space for $STORAGE_DIR")
        return
    fi

    if [[ $storage_space_mb -lt 50000 ]]; then
        WARNINGS+=("$STORAGE_DIR storage space is below the recommended minimum of 50GB")
    fi
}

validate_config_dir() {
    local key="$1"
    local dir_value=$(grep -o "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$CONFIG_FILE" | awk -F'"' '{print $4}')
    
    if [ -z "$dir_value" ]; then
        WARNINGS+=("$key is configured but value is empty in $CONFIG_FILE")
        return 1
    elif [ ! -d "$dir_value" ]; then
        WARNINGS+=("$key is configured but directory does not exist: $dir_value")
        return 1
    fi
    
    echo "$dir_value"
    return 0
}

check_data_storage_space() {
    local data_dir
    local data_space_mb
    local config_key

    # Determine data directory based on config
    if grep -q '"host_persistent_storage_mount_path"' "$CONFIG_FILE"; then
        config_key="host_persistent_storage_mount_path"
        data_dir=$(validate_config_dir "$config_key")
        [ $? -ne 0 ] && return
    elif grep -q '"host_persistent_temp_storage_mount_path"' "$CONFIG_FILE"; then
        config_key="host_persistent_temp_storage_mount_path"
        data_dir=$(validate_config_dir "$config_key")
        [ $? -ne 0 ] && return
    else
        data_dir="$BASE_DIR/data"
    fi

    if [ ! -d "$data_dir" ]; then
        WARNINGS+=("Data directory not found at $data_dir")
        return
    fi

    data_space_mb=$(df -m "$data_dir" 2>/dev/null | awk 'NR==2 {print $2}')
    if [ $? -ne 0 ] || [ -z "$data_space_mb" ]; then
        WARNINGS+=("Unable to determine disk space for $data_dir")
        return
    fi

    if [[ $data_space_mb -lt 50000 ]]; then
        WARNINGS+=("$data_dir storage space is below the recommended minimum of 50GB")
    fi
}

check_selinux() {
    local selinux_status

    if ! command -v sestatus &> /dev/null; then
        return
    fi

    selinux_status=$(sestatus | grep "SELinux status" | awk '{print $3}')
    if [[ "$selinux_status" != "enabled" ]]; then
        return
    fi

    if ! grep -q '"host_selinux_enabled"[[:space:]]*:[[:space:]]*(true|"true")' "$CONFIG_FILE"; then
        WARNINGS+=("SELinux is enabled but 'host_selinux_enabled' is not set to true in $CONFIG_FILE")
    fi
}

check_docker_rootless_compatibility() {
    if [ "$RUNTIME" != "docker" ] || [ "$DOCKER_ROOT" != "$HOME/.local/share/docker" ]; then
        return
    fi

    if grep -q "Amazon Linux 2" /etc/os-release 2>/dev/null; then
        WARNINGS+=("Amazon Linux 2 does not support Docker rootless mode, please use Docker in rootful mode or switch to a different OS")
    fi

    if command -v aa-status >/dev/null 2>&1 && aa-status --enabled 2>/dev/null | grep -q 'enabled'; then
        WARNINGS+=("AppArmor is enabled which may conflict with Docker rootless mode")
    fi
}

check_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        WARNINGS+=("Configuration file $CONFIG_FILE not found")
        return
    fi

    local log_folder
    local docker_sock_path

    if grep -q '"log_folder_path"' "$CONFIG_FILE"; then
        log_folder=$(grep -o '"log_folder_path"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG_FILE" | awk -F'"' '{print $4}')
        if [ -z "$log_folder" ]; then
            WARNINGS+=("Invalid value for log_folder_path: empty path")
        elif [ ! -d "$log_folder" ]; then
            WARNINGS+=("Invalid value for log_folder_path: $log_folder does not exist")
        fi
    fi

    if grep -q '"host_docker_sock_file_path"' "$CONFIG_FILE"; then
        docker_sock_path=$(grep -o '"host_docker_sock_file_path"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG_FILE" | awk -F'"' '{print $4}')
        if [ -z "$docker_sock_path" ]; then
            WARNINGS+=("Invalid value for host_docker_sock_file_path: empty path")
        elif [ "$docker_sock_path" != "$SOCKET" ]; then
            WARNINGS+=("host_docker_sock_file_path does not match detected socket path")
        fi
    fi
}

function check_service_reachability() {
    # Check if we can reach Fivetran endpoints without authentication
    # This is purely to see if we can get to the endpoints, expected response is an error

    # Check if curl is available
    if ! command -v curl &> /dev/null; then
        WARNINGS+=("curl not available, skipping service reachability checks")
        return
    fi

    # non-essential endpoints
    local endpoints=(
        "https://us-docker.pkg.dev/prod-eng-fivetran-ldp/public-docker-us/ldp-agent"
        "https://storage.googleapis.com/fivetran-metrics-log-sr"
    )
    # critical endpoints
    local critical_endpoints=(
        "https://api.fivetran.com/v1/hybrid-deployment-agents"
        "https://ldp.orchestrator.fivetran.com"
    )

    for url in "${endpoints[@]}"; do
        if ! curl -s --max-time ${TIMEOUT} -o /dev/null "$url" 2>/dev/null; then
            local name=$(echo "$url" | sed 's|https://||' | sed 's|/.*||')
            WARNINGS+=("$name is not reachable")
        fi
    done

    for url in "${critical_endpoints[@]}"; do
        if ! curl -s --max-time ${TIMEOUT} -o /dev/null "$url" 2>/dev/null; then
            local name=$(echo "$url" | sed 's|https://||' | sed 's|/.*||')
            ERRORS+=("$name is not reachable")
        fi
    done
}

validate_prerequisites() {
    echo -n "Checking prerequisites... "

    check_container_runtime_version
    check_resources
    check_container_storage_space
    check_data_storage_space
    check_selinux
    check_docker_rootless_compatibility
    check_config
    check_service_reachability

    if [ ${#WARNINGS[@]} -gt 0 ] || [ ${#ERRORS[@]} -gt 0 ]; then
        echo ""
        if [ ${#WARNINGS[@]} -gt 0 ]; then
            echo -e "\nWARNINGS:"
            for warning in "${WARNINGS[@]}"; do
                echo "- $warning"
            done
        fi
        if [ ${#ERRORS[@]} -gt 0 ]; then
            echo -e "\nERRORS:"
            for error in "${ERRORS[@]}"; do
                echo "- $error"
            done
            echo -e "\nPlease resolve the above errors before starting the agent."
        fi
        echo -e "\nFor help with setup, please refer to the setup guide at https://fivetran.com/docs/deployment-models/hybrid-deployment/setup-guide-docker-and-podman\n"
    else
        echo -e "OK\n"
    fi

    if [ ${#ERRORS[@]} -ne 0 ]; then
        return 1
    fi

    return 0
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
        --env TOKEN=$TOKEN \
        --env CONTAINER_ENV_TYPE=$CONTAINER_ENV_TYPE \
        -v $BASE_DIR/conf:/conf \
        -v $BASE_DIR/logs:/logs \
        -v $SOCKET:$INTERNAL_SOCKET \
        $AGENT_IMAGE -f /conf/config.json

    sleep 3
    $RUN_CMD ps -f name="^/?controller" -f label=fivetran=ldp --format "table {{.ID}}\t{{.Names}}\t{{.Status}}"
}


while getopts "r:sh" opt; do
    case "$opt" in
        r)
            if [[ "$OPTARG" == "docker" || "$OPTARG" == "podman" ]]; then
                RUNTIME="$OPTARG"
            else
                echo "Invalid runtime specified. Use 'docker' or 'podman'."
                exit 1
            fi
            ;;
        s)
            SKIP_CHECKS="true"
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

# Run checks only when starting the agent and not skipped
if [[ "$ACTION" == "start" && "$SKIP_CHECKS" != "true" ]]; then
    validate_script_hash
    if ! validate_prerequisites; then
        exit 1
    fi
fi

# Validate the action
case "$ACTION" in
    start)
        echo "Starting Hybrid Deployment agent using $RUNTIME"
        start_agent
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
