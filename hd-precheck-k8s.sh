#!/bin/bash

# This script performs pre-installation checks for the Hybrid Deployment Agent
# in a Kubernetes environment.
#
# Usage:
#   ./hd-precheck-k8s.sh [-n namespace] [-h]
#
# Options:
#   -n namespace   Kubernetes namespace (defaults to 'default')
#   -h             Display this help message and exit
#
# Description and Requirements:
#   - Run this script as a regular user, not root.
#   - This checks the reachability of critical network endpoints required by the agent,
#     as well as the versions of Kubernetes and Helm

ENDPOINTS=(
    "https://ldp.orchestrator.fivetran.com"
    "https://api.fivetran.com/v1/hybrid-deployment-agents"
    "https://us-docker.pkg.dev"
    "https://storage.googleapis.com/fivetran-metrics-log-sr"
)

MIN_K8S_MAJOR=1
MIN_K8S_MINOR=29
MIN_HELM_MAJOR=3
MIN_HELM_MINOR=16
MIN_HELM_PATCH=1

NAMESPACE="default"

ERRORS=()
WARNINGS=()

if [ "$UID" -eq 0 ]; then
    echo -e "This script should not be run as root from the base directory of the Hybrid Deployment Agent.\n Please run as a regular user.\n"
    exit 1
fi

function usage() {
cat <<EOF
  Usage: ./k8s-install.sh [-n namespace] [-h]

  Options:
  -n namespace   Kubernetes namespace (defaults to 'default')
  -h             Display this help message and exit
EOF
    exit 1
}

# Parse command line options
while getopts "n:h" opt; do
    case $opt in
        n) NAMESPACE="$OPTARG" ;;
        h) usage ;;
        \?) echo "Invalid option: -$OPTARG" >&2; usage ;;
    esac
done

shift $((OPTIND-1))

# Check for extra arguments
if [ $# -gt 0 ]; then
    echo "Error: Extra arguments provided: $*"
    usage
    exit 1
fi

echo "Namespace: $NAMESPACE"

POD_NAME="curl-utility-pod-$$"

function printSetupGuideLink() {
    echo
    echo "For help with setup, please refer to the setup guide at https://fivetran.com/docs/deployment-models/hybrid-deployment/setup-guide-kubernetes"
}

function check_endpoints_reachability() {

    CONNECT_TIMEOUT=30

    # We use a trap to ensure the pod is deleted even if the script is interrupted.
    trap 'echo; echo "Interrupt received, cleaning up pod..."; kubectl delete pod "$POD_NAME" --namespace="$NAMESPACE" --ignore-not-found=true --wait=false >/dev/null 2>&1; exit 1' SIGINT SIGTERM

    # STEP 1: Create a single, long-running utility pod.
    # We make it sleep for a long time so it stays alive while we run our commands.
    if ! kubectl run "$POD_NAME" \
      --namespace="$NAMESPACE" \
      --image=curlimages/curl:latest \
      --restart=Never \
      --command -- sleep 3600 > /dev/null; then
        ERRORS+=("Failed to create utility pod '$POD_NAME'. Please check permissions or cluster status.")
        return 1
    fi


    # STEP 2: Wait for the pod to be in the "Running" state.
    # This ensures the pod is fully initialized before we try to exec into it.
    if ! kubectl wait --for=condition=Ready pod/"$POD_NAME" --namespace="$NAMESPACE" --timeout=120s > /dev/null; then
        ERRORS+=("Utility pod '$POD_NAME' did not become ready in time.")
        kubectl delete pod "$POD_NAME" --namespace="$NAMESPACE" --ignore-not-found=true > /dev/null
        return 1
    fi


    # STEP 3: Execute the check for each endpoint inside the running pod.
    # We loop through our endpoints and use `kubectl exec` for each one.
    for url in "${ENDPOINTS[@]}"; do
        # We use 'if kubectl exec ...' to directly check the exit code of the remote curl command.
        if ! kubectl exec --namespace="$NAMESPACE" "$POD_NAME" -- \
          curl -s -o /dev/null --connect-timeout "${CONNECT_TIMEOUT}" --max-time "${CONNECT_TIMEOUT}" --retry 3 --retry-delay 2 "$url" 2>/dev/null; then
            ERRORS+=("Unable to reach endpoint: $url")
        fi
    done

    # STEP 4: Clean up the pod.
    kubectl delete pod "$POD_NAME" --namespace="$NAMESPACE" --ignore-not-found=true > /dev/null
}

function check_k8s_version() {
    # Check kubectl availability
    if ! command -v kubectl &> /dev/null; then
        echo "ERROR: kubectl not found. Please install kubectl."
        printSetupGuideLink
        exit 1
    fi

    local K8S_MAJOR
    local K8S_MINOR

    K8S_SERVER_VERSION=$(kubectl version | grep "Server Version:" | awk '{print $3}')

    if [ -z "$K8S_SERVER_VERSION" ]; then
        echo "ERROR: Could not find 'Server Version:' in kubectl output."
        printSetupGuideLink
        exit 1
    else
        # Remove the 'v' prefix if present
        VERSION_NUMBERS=${K8S_SERVER_VERSION#v}
        # Remove everything after the second dot (e.g., '.5+k3s1' from '1.30.5+k3s1' becomes '1.30')
        VERSION_NUMBERS=$(echo "$VERSION_NUMBERS" | cut -d'.' -f1,2)

        K8S_MAJOR=$(echo "$VERSION_NUMBERS" | cut -d'.' -f1)
        K8S_MINOR=$(echo "$VERSION_NUMBERS" | cut -d'.' -f2)

        # Validate if extracted versions are numbers
        if ! ([[ "$K8S_MAJOR" =~ ^[0-9]+$ ]] && [[ "$K8S_MINOR" =~ ^[0-9]+$ ]]); then
            echo "ERROR: Failed to extract valid major or minor version numbers from '$K8S_SERVER_VERSION'."
            printSetupGuideLink
            exit 1
        fi
    fi

    if (( K8S_MAJOR < MIN_K8S_MAJOR || (K8S_MAJOR == MIN_K8S_MAJOR && K8S_MINOR < MIN_K8S_MINOR) )); then
        WARNINGS+=("Kubernetes version v$K8S_MAJOR.$K8S_MINOR is below required v$MIN_K8S_MAJOR.$MIN_K8S_MINOR")
        return 1
    fi

    return 0
}

function check_helm_version() {
    # Check helm availability
    if ! command -v helm &> /dev/null; then
        ERRORS+=("Helm not found. Please install helm.")
        return 1
    fi

    # Check Helm version
    local HELM_VERSION
    HELM_VERSION=$(helm version --template='{{.Version}}' | sed 's/v//')

    if [ -z "$HELM_VERSION" ]; then
        ERRORS+=("Could not determine Helm version.")
        return 1
    fi

    # Extract version numbers
    local HELM_MAJOR
    local HELM_MINOR
    local HELM_PATCH
    HELM_MAJOR=$(echo "$HELM_VERSION" | cut -d'.' -f1)
    HELM_MINOR=$(echo "$HELM_VERSION" | cut -d'.' -f2)
    HELM_PATCH=$(echo "$HELM_VERSION" | cut -d'.' -f3)

    if ! ([[ "$HELM_MAJOR" =~ ^[0-9]+$ ]] && [[ "$HELM_MINOR" =~ ^[0-9]+$ ]] && [[ "$HELM_PATCH" =~ ^[0-9]+$ ]]); then
        ERRORS+=("Failed to extract valid major, minor or patch version numbers from '$HELM_VERSION'.")
        return 1
    fi

    if (( HELM_MAJOR < MIN_HELM_MAJOR ||
          (HELM_MAJOR == MIN_HELM_MAJOR && HELM_MINOR < MIN_HELM_MINOR) ||
          (HELM_MAJOR == MIN_HELM_MAJOR && HELM_MINOR == MIN_HELM_MINOR && HELM_PATCH < MIN_HELM_PATCH) )); then
        WARNINGS+=("Helm version v$HELM_VERSION is below required v$MIN_HELM_MAJOR.$MIN_HELM_MINOR.$MIN_HELM_PATCH")
        return 1
    fi

    return 0
}

function check_tool_versions() {
    check_helm_version
    check_k8s_version
}

echo
echo -n "Checking prerequisites... "

check_tool_versions
check_endpoints_reachability

if [[ ${#WARNINGS[@]} -gt 0 || ${#ERRORS[@]} -gt 0 ]]; then
    echo
    if [[ ${#WARNINGS[@]} -gt 0 ]]; then
        echo
        echo "WARNINGS:"
        for warning in "${WARNINGS[@]}"; do
            echo "- $warning"
        done

    fi

    if [[ ${#ERRORS[@]} -gt 0 ]]; then
        echo
        echo "ERRORS:"
        for error in "${ERRORS[@]}"; do
            echo "- $error"
        done
        echo
        echo "Please resolve the above error(s) before starting the agent."
    fi

    printSetupGuideLink
else
    echo "OK"
fi
