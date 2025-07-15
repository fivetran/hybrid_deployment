#!/bin/bash
#
# This script provides debugging utilities for the HD agent
#
# Usage:
#   ./hd-debug-k8s.sh [-n namespace] [-h]
#
# Options:
#   -h, --help      Show this help message and exit
#   -n <namespace>  Specify the Kubernetes namespace to check (defaults to 'default')
#
# Requirements:
#   - kubectl must be installed and configured
#   - The HD agent should be installed and running
#
NAMESPACE="default"

# defined in templates/deployment.yaml
HD_AGENT_DEPLOYMENT_CONTAINER_NAME="hd-agent"

function usage() {
cat <<EOF
Usage: $0 [-n <namespace>] [-h]
  -n  Kubernetes namespace (optional, default: default)
  -h  Display this help message
EOF
    exit 1
}

while getopts "n:h" opt; do
    case $opt in
        n)
            NAMESPACE="$OPTARG"
            ;;
        h)
            usage
            ;;
        \?)
            echo "ERROR: Invalid option: -$OPTARG" >&2
            usage
            ;;
        :) # Handles missing arguments for options (e.g., -n without a value)
            echo "ERROR: Option -$OPTARG requires an argument." >&2
            usage
            ;;
        *)
            echo "ERROR: Unhandled error in argument parsing." >&2
            usage
            ;;
    esac
done

shift $((OPTIND-1))

# Check if running as root
if [ "$UID" -eq 0 ]; then
    echo -e "This script should not be run as root from the base directory of the Hybrid Deployment Agent.\n Please run as a regular user.\n"
    exit 1
fi


echo "Namespace: $NAMESPACE"

if [ $# -gt 0 ]; then
    echo "ERROR: Extra arguments provided: $*"
    usage
    exit 1
fi

if ! command -v kubectl &> /dev/null; then
    echo "ERROR: kubectl not found. Please install kubectl."
    exit 1
fi

HD_AGENT_POD_NAME=$(kubectl get pods -n "$NAMESPACE" -o jsonpath="{range .items[*]}{.metadata.name}{'\t'}{.spec.containers[*].name}{'\n'}{end}" | grep "$HD_AGENT_DEPLOYMENT_CONTAINER_NAME" | awk '{print $1}' 2>/dev/null)
if [ -z "$HD_AGENT_POD_NAME" ]; then
    echo "ERROR: Unable to find HD agent pod in namespace '$NAMESPACE'"
    exit 1
fi

SCRIPT_PATH="$(realpath "$0")"
BASE_DIR="$(dirname "$SCRIPT_PATH")"

DIAGNOSTICS_DIR="$BASE_DIR/k8s_stats/"

rm -r "$DIAGNOSTICS_DIR" 2>/dev/null

mkdir -p "$DIAGNOSTICS_DIR" 2>/dev/null
if [ ! -d "$DIAGNOSTICS_DIR" ]; then
    echo "Failed to create diagnostics directory: $DIAGNOSTICS_DIR"
    exit 1
fi
echo -e "Diagnostics location: $DIAGNOSTICS_DIR\n"

TIMESTAMP=$(date +%Y-%m-%d_%H-%M)

ARCHIVE_PATH="$BASE_DIR/k8s_stats/logs-$TIMESTAMP.tar.gz"

function log_agent_info() {
    echo -e "Collecting HD agent pod stats...\n"

    kubectl describe pod "$HD_AGENT_POD_NAME" -n "$NAMESPACE" > "$DIAGNOSTICS_DIR/pod_description.log" 2>&1

    local HD_AGENT_POD_RELEASE_NAME=$(kubectl get pod "$HD_AGENT_POD_NAME" -n "$NAMESPACE" -o jsonpath="{.spec.containers[?(@.name=='$HD_AGENT_DEPLOYMENT_CONTAINER_NAME')].env[?(@.name=='release_name')].value}")

    kubectl top pod "$HD_AGENT_POD_NAME" -n "$NAMESPACE" > "$DIAGNOSTICS_DIR/pod_resource_usage.log" 2>&1

    kubectl get pod "$HD_AGENT_POD_NAME" -n "$NAMESPACE" -o yaml > "$DIAGNOSTICS_DIR/pod_resource_usage.log" 2>&1

    kubectl get configmaps -n "$NAMESPACE" > "$DIAGNOSTICS_DIR/config_maps.log" 2>&1
    
    kubectl get secrets -n "$NAMESPACE" > "$DIAGNOSTICS_DIR/secrets.log" 2>&1

    local HD_AGENT_NODE_NAME=$(kubectl get pod "$HD_AGENT_POD_NAME" -n "$NAMESPACE" -o jsonpath="{.spec.nodeName}")
    kubectl describe node "$HD_AGENT_NODE_NAME" > "$DIAGNOSTICS_DIR/node_description.log" 2>&1

    kubectl get serviceaccounts -n "$NAMESPACE" > "$DIAGNOSTICS_DIR/service_accounts.log" 2>&1

    kubectl get roles -n "$NAMESPACE" > "$DIAGNOSTICS_DIR/roles.log" 2>&1

    kubectl get rolebindings -n "$NAMESPACE" > "$DIAGNOSTICS_DIR/role_bindings.log" 2>&1

    echo "OK"
}

log_agent_info

(cd "$DIAGNOSTICS_DIR" && tar -czf "$ARCHIVE_PATH" *.log)