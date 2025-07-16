#!/bin/bash
#
# This is a helper script to collet and log diagnostics for the Hybrid Deployment Agent in a Kubernetes environment.
#
# Requirements:
#   - kubectl must be installed and configured
#   - The HD agent should be installed and running
#
# Usage:
#   ./hd-debug-k8s.sh [-n namespace] [-h]
#
# set -x
# set -e

# Image for the Hybrid Deployment Agent container
HD_AGENT_IMAGE="us-docker.pkg.dev/prod-eng-fivetran-ldp/public-docker-us/ldp-agent:production"
# defined in templates/deployment.yaml
HD_AGENT_DEPLOYMENT_CONTAINER_NAME="hd-agent"
# defined in templates/configmap.yaml
HD_AGENT_CONFIG_NAME="hd-agent-config"
NAMESPACE="default"
SCRIPT_PATH="$(realpath "$0")"
BASE_DIR="$(dirname "$SCRIPT_PATH")"
DIAG_DIR="$BASE_DIR/k8s_stats/"
TIMESTAMP=$(date +%Y-%m-%d_%H-%M)
AGENT_DEPLOYMENT=""
AGENT_POD=""

rm -r "$DIAG_DIR" 2>/dev/null
mkdir -p "$DIAG_DIR" 2>/dev/null

if [ "$UID" -eq 0 ]; then
    echo -e "This script should not be run as root user.\n"
    exit 1
fi

function usage() {
    echo -e "Usage: $0 [-n <namespace>] [-h]\n"
    exit 1
}

function check_kubectl() {
 if ! command -v kubectl &> /dev/null; then
    echo "kubectl command line utility not found. Please install the latest version."
    echo -e "https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/\n"
    exit 1
 fi
}

function check_helm() {
 if ! command -v helm &> /dev/null; then
    echo "helm command line utility not found. Please install the latest version."
    echo -e "https://helm.sh/docs/intro/install/\n"
    exit 1
 fi
}

function get_agent_deployment_name() {
    AGENT_DEPLOYMENT=$(kubectl get deployments -n "$NAMESPACE" -l app.kubernetes.io/name=hd-agent --no-headers -o custom-columns=":metadata.name")
    if [ -z "$AGENT_DEPLOYMENT" ]; then
        echo "No Agent pod found in '$NAMESPACE'"
    fi
}

function get_agent_pod_name() {
    AGENT_POD=$(kubectl get pod -n "$NAMESPACE" -l app.kubernetes.io/name=hd-agent --no-headers -o custom-columns=":metadata.name")
    if [ -z "$AGENT_POD" ]; then
        echo "No Agent pod found in '$NAMESPACE'"
    fi
}

function get_helm_manifest_for_deployment() {
    helm get manifest "$AGENT_DEPLOYMENT" -n "$NAMESPACE" > "$DIAG_DIR/helm_manifest.log" 2>&1
}

function log_agent_info() {
    echo -e "Collecting HD Agent environment diagnostics...\n"

    get_agent_deployment_name
    get_agent_pod_name

    if [ -z "$AGENT_DEPLOYMENT" ] || [ -z "$AGENT_POD" ]; then
        echo "No HD Agent deployment or pod found in namespace '$NAMESPACE'."
        exit 1
    else
        echo "Found HD Agent deployment: $AGENT_DEPLOYMENT"
        echo "Found HD Agent pod: $AGENT_POD"

        echo "This may take a few seconds..."
    
        kubectl describe pod "$AGENT_POD" -n "$NAMESPACE" > "$DIAG_DIR/pod_description.log" 2>&1
        kubectl get events --field-selector involvedObject.name="$AGENT_POD" -n "$NAMESPACE" -o custom-columns=Message:.message --no-headers > "$DIAG_DIR/pod_events.log" 2>&1
        kubectl top pod "$AGENT_POD" -n "$NAMESPACE" > "$DIAG_DIR/pod_resource_usage.log" 2>&1
        kubectl get pod "$AGENT_POD" -n "$NAMESPACE" -o yaml > "$DIAG_DIR/pod_definition.log" 2>&1
        kubectl get deployment $AGENT_DEPLOYMENT -n "$NAMESPACE" -o yaml > agent_deployment.out 2>&1
        kubectl get pods -n "$NAMESPACE" -o wide > "$DIAG_DIR/pods.log" 2>&1
        kubectl get jobs -n "$NAMESPACE" -o wide > "$DIAG_DIR/jobs.log" 2>&1

        # attempt to get the helm manifest for the deployment
        get_helm_manifest_for_deployment
    fi

    kubectl get configmaps -n "$NAMESPACE" > "$DIAG_DIR/configmap_listing.log" 2>&1
    kubectl get configmap "$HD_AGENT_CONFIG_NAME" -n "$NAMESPACE" -o yaml | grep -v 'token:' > "$DIAG_DIR/agent_config_map.log" 2>&1   
    kubectl get secrets -n "$NAMESPACE" > "$DIAG_DIR/secrets_listing.log" 2>&1

    local HD_AGENT_NODE_NAME=$(kubectl get pod "$AGENT_POD" -n "$NAMESPACE" -o jsonpath="{.spec.nodeName}")
    kubectl describe node "$HD_AGENT_NODE_NAME" > "$DIAG_DIR/node_description.log" 2>&1

    kubectl get serviceaccounts -n "$NAMESPACE" > "$DIAG_DIR/service_accounts.log" 2>&1
    kubectl get roles -n "$NAMESPACE" > "$DIAG_DIR/roles.log" 2>&1
    kubectl get rolebindings -n "$NAMESPACE" > "$DIAG_DIR/role_bindings.log" 2>&1

    kubectl get pv -n "$NAMESPACE" -o wide > "$DIAG_DIR/pv.log" 2>&1
    kubectl get pvc -n "$NAMESPACE" -o wide > "$DIAG_DIR/pvc.log" 2>&1
    kubectl get pvc -n "$NAMESPACE" -o yaml > "$DIAG_DIR/pvc-detail.log" 2>&1
}

while getopts "n:h" opt; do
    case $opt in
        n) NAMESPACE="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done
shift $((OPTIND-1))

if [ $# -gt 0 ]; then
    echo "Error: Extra arguments provided: $*"
    usage
    exit 1
fi

check_kubectl
check_helm
log_agent_info

echo -e "done.\n"
echo -e "Packing logs into hd-logs-$TIMESTAMP.tar.gz\n"

cd $DIAG_DIR 
tar czf hd-logs-$TIMESTAMP.tar.gz ./*.log
ls -altr hd-logs-$TIMESTAMP.tar.gz
cd - 

echo -e "done.\n"
echo -e "Logs are available in $DIAG_DIR/hd-logs-$TIMESTAMP.tar.gz\n"
