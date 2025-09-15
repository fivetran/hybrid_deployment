#!/bin/bash
#
#  This script is a helper script to collect logs and stats from the host running the Hybrid Deployment Agent.
#
#  Description and Requirements:
#  - Run this script as a regular user, not root.
#  - Run this script from the base directory of the Hybrid Deployment Agent, example $HOME/fivetran.
#  - The script will create a directory called "stats" in the base directory and save the logs there.
#  - The script will check for the presence of Docker or Podman and set the environment accordingly.
#  - Output will be saved in the stats sub directory.
#
#  Important Notice:
#   - This will log the user ENVIRONMENT (env).  
#   - If any sensitive information is in the environment variables, please exclude this check use the "-x env" option.
#
#  usage: ./hd-debug.sh [-r docker|podman]
#
# set -x
# set -e


if [ "$UID" -eq 0 ]; then
  echo -e "This script should not be run as root from the base directory of the Hybrid Deployment Agent.\n Please run as a regular user.\n"
  exit 1
fi

function usage() {
cat <<EOF
    Usage: $0 [-r docker|podman] [-x env] \n
    -r <docker|podman>  Specify the container runtime to use (default: auto-detect)
    -x <env>            Exclude environment variables from logs (default: include)
    -h                  Show this help message and exit
    \n
    Run script as a regular user, not root from the base directory of the Hybrid Deployment Agent. \n
    Example: 
        cd $HOME/fivetran
        $0 -r docker \n

    Example: $0 -r docker -x env \n
    Example: $0 -r podman \n

EOF
    exit 1
}

SCRIPT_PATH="$(realpath "$0")"
BASE_DIR="$(dirname "$SCRIPT_PATH")"
echo -e "Base location: $BASE_DIR\n"

if [ ! -f "$BASE_DIR/hdagent.sh" ]; then
    echo "Base directory with hdagent.sh not found: $BASE_DIR/hdagent.sh"
    echo -e "Make sure this script is executed in the base directory of the Hybrid Deployment Agent (example \$HOME/fivetran).\n"
    exit 1
fi

STATS_DIR="$BASE_DIR/stats"
mkdir -p $STATS_DIR 2>/dev/null
echo -e "Stats location: $STATS_DIR\n"

CONFIG_FILE=$BASE_DIR/conf/config.json
TOKEN=""
CONTROLLER_ID="unknown_controller_id"
SOCKET=""
RUN_CMD=""
RUNTIME=""
INTERNAL_SOCKET=""
CONTAINER_ENV_TYPE=""
CONTEXT=""
SERVICE_CONFIG=""
EXCLUDE_ENV="false"


function get_token_from_config() {
    # Extract the token from the config file, if it exists
    # The token is expected to be in the format: "token": "your_token_here"
    # the token contains the controller id (agent id)
    if [[ -f "$CONFIG_FILE" ]]; then
        grep -o '"token": *"[^"]*"' "$CONFIG_FILE" | sed 's/.*"token": *"\([^"]*\)".*/\1/'
    fi
}


function set_environment() {
    # Set the environment depending on docker or podman 

    RUN_CMD="$1"

    # ensure command is available and in path
    if ! command -v "$RUN_CMD" &> /dev/null
    then
        echo "$RUN_CMD is not installed or not in the PATH."
        exit 1
    fi

    case "$1" in
    "podman")
        # podman is used
        CONTAINER_ENV_TYPE="podman"
        # check if podman is running in rootless mode
        if podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null | grep -q 'true'; then
            SOCKET="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/podman/podman.sock"
            SERVICE_CONFIG=$(systemctl --user cat podman.service)
        else
            SOCKET="/run/podman/podman.sock"
            SERVICE_CONFIG=$(systemctl cat podman.service)
        fi
        ;;

    "docker")
        # docker is used
        CONTAINER_ENV_TYPE="docker"
        DOCKER_ROOT=$(docker info --format '{{.DockerRootDir}}')
        # check if docker is running in rootless mode
        if [ "$DOCKER_ROOT" == "$HOME/.local/share/docker" ]; then
            uid=$(id -u)
            SOCKET="/var/run/user/$uid/docker.sock"
            SERVICE_CONFIG=$(systemctl --user cat docker.service)
        else
            SOCKET="/var/run/docker.sock"
            SERVICE_CONFIG=$(systemctl cat docker.service)
        fi
        ;;

    *)
        echo "Invalid runtime specified. Use docker or podman."
        exit 1
        ;;

    esac

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
        echo "Invalid controller-id format, please supply valid token, will use "unknown" controller id"
        CONTROLLER_ID="unknown"
    else
        echo "The Agent (Controller) ID: $CONTROLLER_ID"
    fi
}

function log_registry_access () {
    if 
    [[ "$CONTAINER_ENV_TYPE" == "docker" ]]; then
        docker manifest inspect us-docker.pkg.dev/prod-eng-fivetran-ldp/public-docker-us/ldp-agent:production > "$STATS_DIR/docker_registry_access.log" 2>&1
    elif [[ "$CONTAINER_ENV_TYPE" == "podman" ]]; then
        podman manifest inspect us-docker.pkg.dev/prod-eng-fivetran-ldp/public-docker-us/ldp-agent:production > "$STATS_DIR/podman_registry_access.log" 2>&1
    fi
}

function log_container_info() {
    # Log the docker or podman info to a file
    echo "$SERVICE_CONFIG" > "$STATS_DIR/service_config.log" 2>&1

    if [[ "$CONTAINER_ENV_TYPE" == "docker" ]]; then
        docker info > "$STATS_DIR/docker_info.log" 2>&1
        docker ps -a > "$STATS_DIR/docker_ps.log" 2>&1
        docker network ls > "$STATS_DIR/docker_network.log" 2>&1
        docker system df > "$STATS_DIR/docker_system_df.log" 2>&1
        docker system df -v > "$STATS_DIR/docker_system_df_v.log" 2>&1
        ps -ef|grep -i docker > "$STATS_DIR/docker_process.log" 2>&1
        
        docker logs $(docker ps --filter "name=^/controller" --format "{{.Names}}") > "$STATS_DIR/docker_controller.log" 2>&1
        docker inspect $(docker ps --filter "name=^/controller" --format "{{.Names}}") > "$STATS_DIR/docker_controller_inspect.log" 2>&1
        sed -E '/"TOKEN=.*"/d; /"*.client_private_key=.*"/d; /"*.client_cert=.*"/d; /"*.clientCert=.*"/d' "$STATS_DIR/docker_controller_inspect.log" > "$STATS_DIR/docker_agent_inspect.log"
        rm $STATS_DIR/docker_controller_inspect.log

        ls -al $HOME/.docker > "$STATS_DIR/docker_home.log" 2>&1
        if [ -f $HOME/.docker/config.json ]; then
            sed -E 's/("auth"[[:space:]]*:[[:space:]]*")[^"]*"/\1***"/' $HOME/.docker/config.json > "$STATS_DIR/docker_home_config.json.log" 2>&1
        fi
        ls -al /etc/docker > "$STATS_DIR/docker_etc.log" 2>&1
        if [ -f /etc/docker/daemon.json ]; then
            cat /etc/docker/daemon.json > "$STATS_DIR/docker_daemon.json.log" 2>&1
        fi

    elif [[ "$CONTAINER_ENV_TYPE" == "podman" ]]; then
        podman info > "$STATS_DIR/podman_info.log" 2>&1
        podman ps -a > "$STATS_DIR/podman_ps.log" 2>&1
        podman network ls > "$STATS_DIR/podman_network.log" 2>&1
        podman system df > "$STATS_DIR/podman_system_df.log" 2>&1
        podman system df -v > "$STATS_DIR/podman_system_df_v.log" 2>&1
        ps -ef|grep -i podman > "$STATS_DIR/podman_process.log" 2>&1

        podman logs $(podman ps --filter "name=^/controller" --format "{{.Names}}") > "$STATS_DIR/podman_controller.log" 2>&1
        podman inspect $(podman ps --filter "name=^/controller" --format "{{.Names}}") > "$STATS_DIR/podman_controller_inspect.log" 2>&1
        sed -E '/"TOKEN=.*"/d; /"*.client_private_key=.*"/d; /"*.client_cert=.*"/d; /"*.clientCert=.*"/d' "$STATS_DIR/podman_controller_inspect.log" > "$STATS_DIR/podman_agent_inspect.log"
        rm $STATS_DIR/podman_controller_inspect.log

        # rootless (user) podman config
        ls -al $HOME/.config/containers > "$STATS_DIR/podman_home.log" 2>&1
        if [ -f $HOME/.config/containers/storage.conf ]; then
            cat $HOME/.config/containers/storage.conf > "$STATS_DIR/podman_home_storage.conf.log" 2>&1
        fi
        if [ -f $HOME/.config/containers/registries.conf ]; then
            cat $HOME/.config/containers/registries.conf > "$STATS_DIR/podman_home_registries.conf.log" 2>&1
        fi
        if [ -f $HOME/.config/containers/policy.json ]; then
            cat $HOME/.config/containers/policy.json > "$STATS_DIR/podman_home_policy.json.log" 2>&1
        fi
        if [ -f $HOME/.config/containers/containers.conf ]; then
            cat $HOME/.config/containers/containers.conf > "$STATS_DIR/podman_home_containers.conf.log" 2>&1
        fi

        # rootfull (system) podman config
        ls -al /etc/containers > "$STATS_DIR/podman_etc.log" 2>&1
        if [ -f /etc/containers/registries.conf ]; then
            cat /etc/containers/registries.conf > "$STATS_DIR/podman_registries.conf.log" 2>&1
        fi
        if [ -f /etc/containers/storage.conf ]; then
            cat /etc/containers/storage.conf > "$STATS_DIR/podman_storage.conf.log" 2>&1
        fi
        if [ -f /etc/containers/policy.json ]; then
            cat /etc/containers/policy.json > "$STATS_DIR/podman_policy.json.log" 2>&1
        fi
        if [ -f /etc/containers/containers.conf ]; then
            cat /etc/containers/storage.conf > "$STATS_DIR/podman_storage.conf.log" 2>&1
        fi        
    fi
}

function log_base_dir_info () {
    # Log the disk space usage in key subdirectories of the base directory
    ls -altr $BASE_DIR > "$STATS_DIR/base_dir_file_listing.log" 2>&1
    du -sh $BASE_DIR > "$STATS_DIR/base_dir_size.log" 2>&1
    du -sh $BASE_DIR/* >> "$STATS_DIR/base_dir_size.log" 2>&1

    if [ -n "$BASE_DIR/log" ]; then
        ls -altr $BASE_DIR/logs > "$STATS_DIR/base_dir_logs.log" 2>&1
    fi
    if [ -n "$BASE_DIR/data" ]; then
        du -sh $BASE_DIR/data > "$STATS_DIR/base_dir_data_size.log" 2>&1
        du -sh $BASE_DIR/data/* >> "$STATS_DIR/base_dir_data_size.log" 2>&1
        ls -altr $BASE_DIR/data > "$STATS_DIR/base_dir_data_file_listing.log" 2>&1
        
        du -sh $BASE_DIR/data/_samples > "$STATS_DIR/base_dir_data_samples_size.log" 2>&1
        ls -altr $BASE_DIR/data/_samples > "$STATS_DIR/base_dir_data_samples_file_listing.log" 2>&1
    fi
    if [ -n "$BASE_DIR/tmp" ]; then
        du -sh $BASE_DIR/tmp > "$STATS_DIR/base_dir_tmp_size.log" 2>&1
        ls -altr $BASE_DIR/tmp > "$STATS_DIR/base_dir_tmp_file_listing.log" 2>&1
    fi
}

function log_disk_space () {
    # Log the disk space usage to a file
    df -h > "$STATS_DIR/system_disk_space_df_h.log" 2>&1
}

function log_resources () {
    # Log the resource usage to a file
    cat /proc/cpuinfo > "$STATS_DIR/system_proc_cpuinfo.log" 2>&1
    cat /proc/meminfo > "$STATS_DIR/system_proc_meminfo.log" 2>&1
    uptime > "$STATS_DIR/system_uptime.log" 2>&1
    uname -a > "$STATS_DIR/system_uname_a.log" 2>&1
}

function log_os_version () {
    # Log the OS version and hostname to a file
    cat /proc/sys/kernel/hostname > "$STATS_DIR/system_hostname.log" 2>&1
    cat /etc/os-release > "$STATS_DIR/system_os_release.log" 2>&1
}

function log_network_stats () {
    sar -n EDEV > "$STATS_DIR/system_sar_n_edev.log" 2>&1
    ip -s link > "$STATS_DIR/system_ip_s_link.log" 2>&1
    ip -brief addr show > "$STATS_DIR/system_ip_brief_addr.log" 2>&1
    cat /etc/resolv.conf |grep -v "^#" > "$STATS_DIR/system_etc_resolv_conf.log" 2>&1
}

function log_user () {
    # Log the user information to a file
    whoami > "$STATS_DIR/current_user.log" 2>&1
    id > "$STATS_DIR/current_user_id.log" 2>&1
    groups > "$STATS_DIR/current_user_groups.log" 2>&1
}

function log_env () {
    env | sort > "$STATS_DIR/current_user_env.log" 2>&1
}

function log_selinux() {
    # Log the SELinux status
    if ! command -v sestatus &> /dev/null
    then
        echo "selinux is not installed/used or not in the PATH." > "$STATS_DIR/system_selinux_status.log"
    else
        sestatus > "$STATS_DIR/system_selinux_status.log" 2>&1
    fi
}

function log_apparmor() {
    # Log the AppArmor status
    if ! command -v aa-status &> /dev/null
    then
        echo "App Armor is not installed/used or not in the PATH." > "$STATS_DIR/system_apparmor_status.log"
    else
        aa-status > "$STATS_DIR/system_apparmor_status.log" 2>&1
    fi
}


function log_base_acl() {
    # Log the base ACL
    getfacl -aR $BASE_DIR > "$STATS_DIR/base_location_acl.log" 2>&1
}

function check_nofiles_inotify() {
    ulimit -a > $STATS_DIR/system_ulimit_a.log 2>&1
    ulimit -n > $STATS_DIR/system_ulimit_n.log 2>&1
    cat /proc/sys/fs/inotify/max_user_watches > $STATS_DIR/system_proc_sys_fs_inotify_max_user_watches.log 2>&1
    cat /proc/sys/fs/inotify/max_user_instances > $STATS_DIR/system_proc_sys_fs_inotify_max_user_instances.log 2>&1
    cat /etc/security/limits.conf > $STATS_DIR/system_etc_limits_conf.log 2>&1
}

function log_config () {
    # Log the config file to a file
    if [[ -f "$CONFIG_FILE" ]]; then
        sed -E 's/("token"[[:space:]]*:[[:space:]]*")[^"]*"/\1***"/' "$CONFIG_FILE" > "$STATS_DIR/hdagent_config.log"
    else
        echo "Config file not found: $CONFIG_FILE"
    fi
}

function test_api_fivetran_com () {
    # expected: {"code":"AuthFailed","message":"Missing authorization header"} as we did not pass in token,
    # this is purely to see if we can get to the API 

    curl -v https://api.fivetran.com/v1/hybrid-deployment-agents > "$STATS_DIR/connectivity_api_fivetran_com.log" 2>&1
}

function test_orchestrator_com () {
    # expected: {"code":"AuthFailed","message":"Missing authorization header"} as we did not pass in token,
    # this is purely to see if we can get to the API 

    curl -v https://ldp.orchestrator.fivetran.com > "$STATS_DIR/connectivity_orchestrator_fivetran_com.log" 2>&1
}

function get_conntrack_values() {
    # Review current conntrack values
    cat /proc/sys/net/netfilter/nf_conntrack_count > "$STATS_DIR/system_proc_sys_net_netfilter_nf_conntrack_count.log"
    cat /proc/sys/net/netfilter/nf_conntrack_max > "$STATS_DIR/system_proc_sys_net_netfilter_nf_conntrack_max.log"
    
}

function get_user_systemd_configuration() {
    # Get the user systemd configuration in case user configured systemd for hdagent
    ls -altr ~/.config/systemd/user > "$STATS_DIR/user_systemd_config.log" 2>&1
    if command -v systemctl &> /dev/null; then
        systemctl --user show-environment > "$STATS_DIR/user_systemd_environment.log" 2>&1
        systemctl --user list-unit-files --no-pager > "$STATS_DIR/user_systemd_units.log" 2>&1
        systemctl --user status --no-pager> "$STATS_DIR/user_systemd_status.log" 2>&1
    fi
}

###
### Main script execution
###

[ -f "$CONFIG_FILE" ] || {
    echo "Config file not found: $CONFIG_FILE"
    echo -e "Make sure this script is executed in the base directory of the Hybrid Deployment Agent (example \$HOME/fivetran).\n"
    sleep 2 
    exit 1
}

while getopts "r:x:h" opt; do
    case "$opt" in
        r)
            if [[ "$OPTARG" == "docker" || "$OPTARG" == "podman" ]]; then
                RUNTIME="$OPTARG"
            else
                echo "Invalid runtime specified. Use docker or podman."
                exit 1
            fi
            ;;
        x)
            if [[ "$OPTARG" == "env" ]]; then
                EXCLUDE_ENV="true"
            else
                echo "Invalid exclude option specified. Use env."
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

rm -f $STATS_DIR/*.log
rm -f $STATS_DIR/*.tar.gz

echo -e "Collecting logs and stats...\n"
check_nofiles_inotify
log_container_info
log_disk_space
log_base_dir_info
log_config
log_resources
log_network_stats
get_conntrack_values

if [[ "$EXCLUDE_ENV" == "true" ]]; 
then
    echo "Excluding environment variables from logs."
else
    log_env
fi

log_selinux
log_apparmor
log_os_version
log_base_acl
log_user
get_user_systemd_configuration
test_api_fivetran_com
test_orchestrator_com

echo -e "done.\n"
echo -e "Packing logs into logs.tar.gz\n"

cd $STATS_DIR 
tar czf ./logs-$CONTROLLER_ID.tar.gz ./*.log
ls -altr ./logs-$CONTROLLER_ID.tar.gz
cd - 

echo -e "done.\n"
echo -e "Logs are available in $STATS_DIR/logs-$CONTROLLER_ID.tar.gz\n"

