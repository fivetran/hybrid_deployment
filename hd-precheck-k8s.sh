#!/bin/bash
#
# Description:
# This script performs pre-installation checks for the Hybrid Deployment Agent
# in a Kubernetes environment.
#
# Requirements:
# - kubectl command line utility
# - helm command line utility
# - Access to a Kubernetes cluster
# - A namespace in which to deploy the test pod - defaults to "default"
#
set -euo pipefail

# minimum required versions for the Hybrid Deployment Agent deployment.
MIN_HELM_VERSION=3.16.1
MIN_K8S_VERSION=1.29.0

# Image for the Hybrid Deployment Agent container
HD_AGENT_IMAGE="us-docker.pkg.dev/prod-eng-fivetran-ldp/public-docker-us/ldp-agent:production"
NAMESPACE="default"
TEST_POD_NAME="hd-test-$$-pod"
# For slower networks or clusters, you may want to increase the timeout
TIMEOUT=60

# Key endpoints to verify connectivity
ENDPOINTS=(
    "https://ldp.orchestrator.fivetran.com"
    "https://api.fivetran.com/v1/hybrid-deployment-agents"
    "https://us-docker.pkg.dev"
    "https://storage.googleapis.com/fivetran-metrics-log-sr"
)


if [ "$UID" -eq 0 ]; then
    echo -e "This script should not be run as root user.\n"
    exit 1
fi

function usage() {
cat <<EOF
  Usage: ./hd-precheck-k8s.sh [-n namespace] [-h]
EOF
    exit 1
}

function check_version () {
    # Pass in two arguments: version ($1) and minimum required version ($2)
    local version="$1"
    local min_version="$2"
    if [ "$(printf '%s\n' "$min_version" "$version" | sort -V | head -n1)" = "$min_version" ]; then
        echo -e " - OK.\n"
    else
        echo -e " - FAIL.\nDoes not meet required minimum version $min_version\n"
    fi
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

function strip_k8s_version_from_special_chars() {
    local version="$1"
    # Remove 'v' prefix and any suffixes like '+k3s, -eks, -gke etc.'
    echo "$version" | sed -E 's/^v?([0-9]+\.[0-9]+\.[0-9]+).*$/\1/'
}

function check_k8s_version() {
    local K8S_RAW_VERSION=$(kubectl version 2>/dev/null | grep "Server Version:" | awk '{print $3}')

    if [ -z "$K8S_RAW_VERSION" ]; then
        echo -e "Unable to determine Kubernetes version.\nPlease review output of 'kubectl version' command and ensure you have access to the Kubernetes cluster.\n"
        exit 1
    else
        echo -n "Kubernetes server version: $K8S_RAW_VERSION"
        local K8S_VERSION=$(strip_k8s_version_from_special_chars "$K8S_RAW_VERSION")
        # Check if the version is below the minimum required version
        check_version "$K8S_VERSION" "$MIN_K8S_VERSION"
    fi
}

function check_helm_version() {
    local HELM_VERSION
    HELM_VERSION=$(helm version --template='{{.Version}}' | sed 's/v//')

    if [ -z "$HELM_VERSION" ]; then
        echo -e "Could not determine Helm version.\nPlease review output of 'helm version' command.\n"
        exit 1
    else
        echo -n "Helm version: $HELM_VERSION"
        # Check if the version is below the minimum required version
        check_version "$HELM_VERSION" "$MIN_HELM_VERSION"
    fi
}

function check_namespace_exist() {
  if ! kubectl get namespace "$NAMESPACE" > /dev/null 2>&1; then
    echo "Namespace '$NAMESPACE' does not exist."
    exit 1
  fi
}

function list_kubectl_current_context(){
    local CURRENT_CONTEXT=$(kubectl config current-context)
    if [ -z "$CURRENT_CONTEXT" ]; then
        echo -e "No current kubectl context set.\nPlease set a valid context pointing to your cluster.\n"
        exit 1
    else
        echo -e "Current kubectl context: $CURRENT_CONTEXT\n"
    fi
}

function add_curl_to_pod() {
    # Add curl to the utility pod if not already present
    if kubectl exec --namespace="$NAMESPACE" "$TEST_POD_NAME" -- bash -c "apt update && apt install -y curl" > /dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

function verify_key_endpoints() {
  # Verifying outbound connectivity to key endpoints from pod
  local CONNECT_TIMEOUT=10

  for url in "${ENDPOINTS[@]}"; do
    if ! kubectl exec --namespace="$NAMESPACE" "$TEST_POD_NAME" -- \
      curl -s -o /dev/null \
           --connect-timeout "$CONNECT_TIMEOUT" \
           --max-time "$CONNECT_TIMEOUT" \
           --retry 3 \
           --retry-delay 2 \
           "$url" 2>/dev/null; then

      echo "- ${url} - FAIL"
      echo -e "Please check your network connectivity, firewall rules, or DNS settings.\n"
    else
      echo "- ${url} - OK"
    fi
  done
}

function verify_pod_running() {
    echo "Waiting for pod to start (timeout ${TIMEOUT}s)..."

    # SECONDS is a built-in variable that counts the number of seconds since the script started
    SECONDS=0
    while true; do
        status=$(kubectl get pod "$TEST_POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
        
        case "$status" in
            Running|Succeeded)
                echo -e "Pod started successfully.\n"                
                # kubectl get pod "$TEST_POD_NAME" -n "$NAMESPACE" -o wide
                echo -e "Pod events:\n----"
                kubectl get events --field-selector involvedObject.name="$TEST_POD_NAME" -n "$NAMESPACE" -o custom-columns=Message:.message --no-headers
                echo -e "----\n"
                if add_curl_to_pod; then
                    echo "Testing connectivity to key endpoints from the pod: "
                    verify_key_endpoints
                    echo -e "\nConnectivity check completed.\n"
                else
                    echo "Failed to install curl in the test pod. Please check your Kubernetes cluster and permissions"
                fi
                kubectl delete pod "$TEST_POD_NAME" -n "$NAMESPACE" --wait=false
                return 0
            ;;
            Failed)
                echo "Pod failed to start."
                kubectl describe pod "$TEST_POD_NAME" -n "$NAMESPACE"
                kubectl logs "$TEST_POD_NAME" -n "$NAMESPACE" || true
                return 1
            ;;
            NotFound)
                echo "Waiting for pod to be created..."
            ;;
            *)
                echo "Pod status: $status"
            ;;
        esac

        if (( SECONDS >= TIMEOUT )); then
            echo "Timeout after $TIMEOUT seconds waiting for pod to start.  Getting pod details..."
            kubectl get events --field-selector involvedObject.name="$TEST_POD_NAME" -n "$NAMESPACE" || true
            kubectl describe pod "$TEST_POD_NAME" -n "$NAMESPACE" || true
            kubectl logs "$TEST_POD_NAME" -n "$NAMESPACE" || true
            kubectl delete pod "$TEST_POD_NAME" -n "$NAMESPACE" --wait=false || true
            return 1
        fi
        sleep 3
    done
}

function create_test_pod () {

    echo "Creating a test pod $TEST_POD_NAME to verify image download and run connectivity tests\n"

cat <<EOF | kubectl apply -n "$NAMESPACE" -f -
apiVersion: v1
kind: Pod
metadata:
  name: $TEST_POD_NAME
spec:
  containers:
  - name: test-container
    image: "$HD_AGENT_IMAGE"
    imagePullPolicy: Always
    command: ["/bin/bash"]
    args: ["-c", "sleep 60"]
  restartPolicy: Never
EOF

    verify_pod_running "$NAMESPACE"
    if [ $? -ne 0 ]; then
        echo "Failed to create or run the test pod. Please check your Kubernetes cluster and permissions."
        exit 1
    fi
}

#
# Main script execution starts here
#

while getopts "n:h" opt; do
    case $opt in
        n) NAMESPACE="$OPTARG" ;;
        h) usage ;;
        \?) echo "Invalid option: -$OPTARG" >&2; usage ;;
    esac
done
shift $((OPTIND-1))

if [ $# -gt 0 ]; then
    echo "Error: Extra arguments provided: $*"
    usage
    exit 1
fi

# Start pre-checks
echo -e "Checking prerequisites... \n"
check_kubectl
check_helm
check_namespace_exist
check_k8s_version
check_helm_version  
list_kubectl_current_context
create_test_pod
echo -e "\nDone.\n"
