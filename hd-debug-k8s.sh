#!/bin/bash
#
# This script provides debugging utilities for the HD agent
#
# Usage:
#   ./hd-debug-k8s.sh [-n namespace] [-h] [-p pvc]
#
# Options:
#   -h, --help      Show this help message and exit
#   -n <namespace>  Specify the Kubernetes namespace to check (defaults to 'default')
#   -p <pvc>        Specify the Persistent Volume Claim name to test. The script only performs write tests on PVC if it's provided.
#
# Requirements:
#   - kubectl must be installed and configured
#   - The HD agent should be installed and running
#
NAMESPACE="default"

# defined in templates/deployment.yaml
HD_AGENT_DEPLOYMENT_CONTAINER_NAME="hd-agent"

# defined in templates/configmap.yaml
HD_AGENT_CONFIG_NAME="hd-agent-config"

# defined in templates/rbac.yaml
HD_JOB_SA_NAME="hd-job-sa"
HD_AGENT_SA_NAME="hd-agent-sa"
HD_AGENT_ROLE_NAME="hd-agent-role"
HD_JOB_ROLE_NAME="hd-job-role"
HD_AGENT_EVENT_READER_ROLE_NAME="hd-agent-event-reader"
HD_AGENT_ROLE_BINDING="hd-agent-rolebinding"
HD_JOB_ROLE_BINDING="hd-job-rolebinding"
HD_AGENT_EVENT_READER_ROLE_BINDING="hd-agent-event-reader-binding"

ENDPOINTS=(
    "https://ldp.orchestrator.fivetran.com"
    "https://api.fivetran.com/v1/hybrid-deployment-agents"
    "https://us-docker.pkg.dev"
    "https://storage.googleapis.com/fivetran-metrics-log-sr"
)

PVC_NAME=""

function usage() {
cat <<EOF
Usage: $0 [-n <namespace>] [-p <pvc_name>] [-h]
  -n  Kubernetes namespace (optional, default: default)
  -p  Persistent Volume Claim name to test (optional)
  -h  Display this help message
EOF
    exit 1
}

while getopts "n:p:h" opt; do
    case $opt in
        n)
            NAMESPACE="$OPTARG"
            ;;
        p) # This now handles -p for PVC_NAME
            PVC_NAME="$OPTARG"
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

if [ -n "$PVC_NAME" ]; then
    echo "PVC to test: $PVC_NAME"
fi

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

rm -r "$DIAGNOSTICS_DIR"

mkdir -p "$DIAGNOSTICS_DIR" 2>/dev/null
if [ ! -d "$DIAGNOSTICS_DIR" ]; then
    echo "Failed to create diagnostics directory: $DIAGNOSTICS_DIR"
    exit 1
fi
echo -e "Diagnostics location: $DIAGNOSTICS_DIR\n"

TIMESTAMP=$(date +%Y-%m-%d_%H-%M)

ARCHIVE_PATH="$BASE_DIR/k8s_stats/logs-$TIMESTAMP.tar.gz"

UTIL_POD_NAME="diag-utility-pod-$$"
PVC_MOUNT_PATH="/mnt/test-volume"

function cleanup_utility_pod() {
    kubectl delete pod "$UTIL_POD_NAME" --namespace="$NAMESPACE" --ignore-not-found=true --wait=false >/dev/null 2>&1
    rm -f "$DIAGNOSTICS_DIR/${UTIL_POD_NAME}.yaml" # Clean up temporary pod definition file
}

# Register cleanup function to run on exit or signal
trap 'cleanup_utility_pod; exit' EXIT SIGINT SIGTERM


VOLUME_MOUNTS_YAML=""
VOLUMES_YAML=""
PVC_LOG_FILE="$DIAGNOSTICS_DIR/pvc.log"

function precheck_pvc() {
    touch "$PVC_LOG_FILE"
    echo -n > "$PVC_LOG_FILE"
    if [ -n "$PVC_NAME" ]; then
        local PVC_STATUS=$(kubectl get pvc "$PVC_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null)
        if [ -z "$PVC_STATUS" ]; then
            echo "Provided PVC '$PVC_NAME' not found in namespace '$NAMESPACE'. Cannot proceed with PVC tests." >> "$PVC_LOG_FILE"
            return 1
        elif [ "$PVC_STATUS" != "Bound" ]; then
            echo "Provided PVC '$PVC_NAME' is not Bound. Current status: $PVC_STATUS. Cannot proceed with PVC tests." >> "$PVC_LOG_FILE"
            return 1
        else
            echo "PVC '$PVC_NAME' is bound." >> "$PVC_LOG_FILE"
            VOLUME_MOUNTS_YAML=$(cat <<VMOUNTS_EOF
    volumeMounts:
      - name: pvc-volume
        mountPath: ${PVC_MOUNT_PATH}
VMOUNTS_EOF
            )
            VOLUMES_YAML=$(cat <<VOLS_EOF
  volumes:
    - name: pvc-volume
      persistentVolumeClaim:
        claimName: ${PVC_NAME}
VOLS_EOF
            )
        fi
    else
        echo "No PVC provided. Will skip testing for PVC." | tee -a "$PVC_LOG_FILE"
    fi


    # Create temporary YAML file for the utility pod
    cat <<EOF > "${DIAGNOSTICS_DIR}/${UTIL_POD_NAME}.yaml"
apiVersion: v1
kind: Pod
metadata:
  name: ${UTIL_POD_NAME}
  namespace: ${NAMESPACE}
spec:
  restartPolicy: Never
  securityContext:
    fsGroup: 0
  containers:
  - name: util-container
    image: curlimages/curl:latest # Use curl image for network tests, also has shell
    command: ["sleep", "infinity"] # Keep container alive
${VOLUME_MOUNTS_YAML}
${VOLUMES_YAML}
EOF
}

function create_and_wait_utility_pod() {
    if ! precheck_pvc 2>&1; then
      return 1
    fi

    echo -n "Creating temporary pod for testing..."

    if ! kubectl apply -f "${DIAGNOSTICS_DIR}/${UTIL_POD_NAME}.yaml" >/dev/null 2>&1; then
        echo "Failed to create utility pod '$UTIL_POD_NAME'." >> "$PVC_LOG_FILE"
        echo "FAILED"
        return 1
    fi

    # Wait for the pod to be ready
    if ! kubectl wait --for=condition=Ready pod/"$UTIL_POD_NAME" --namespace="$NAMESPACE" --timeout=120s >/dev/null 2>&1; then
        echo "Pod '$UTIL_POD_NAME' did not become ready in time." >> "$PVC_LOG_FILE"
        kubectl logs "$UTIL_POD_NAME" --namespace="$NAMESPACE" >> "$PVC_LOG_FILE"
        kubectl describe pod "$UTIL_POD_NAME" --namespace="$NAMESPACE" >> "$PVC_LOG_FILE"
        echo "FAILED"
        return 1
    fi

    echo "OK"

    return 0
}


function check_agent_pod() {
    echo -n "Collecting HD agent pod stats..."

    local AGENT_POD_CHECKS_PASSED=true

    # Describe the HD_AGENT_POD_NAME
    kubectl describe pod "$HD_AGENT_POD_NAME" -n "$NAMESPACE" > "$DIAGNOSTICS_DIR/pod_description.log" 2>&1

    local HD_AGENT_POD_RELEASE_NAME=$(kubectl get pod "$HD_AGENT_POD_NAME" -n "$NAMESPACE" -o jsonpath="{.spec.containers[?(@.name=='$HD_AGENT_DEPLOYMENT_CONTAINER_NAME')].env[?(@.name=='release_name')].value}")

    # Top HD_AGENT_POD_NAME's CPU and memory used
    kubectl top pod "$HD_AGENT_POD_NAME" -n "$NAMESPACE" > "$DIAGNOSTICS_DIR/pod_resource_usage.log" 2>&1

    # YAML spec of the HD agent pod
    kubectl get pod "$HD_AGENT_POD_NAME" -n "$NAMESPACE" -o yaml > "$DIAGNOSTICS_DIR/pod_resource_usage.log" 2>&1

    # ConfigMap
    if ! kubectl get configmap "$HD_AGENT_CONFIG_NAME" -n "$NAMESPACE" > "$DIAGNOSTICS_DIR/config_maps.log" 2>&1; then
        echo "ERROR: $HD_AGENT_CONFIG_NAME configmap is missing" > "$DIAGNOSTICS_DIR/config_maps.log"
        AGENT_POD_CHECKS_PASSED=false
    fi
    
    # Secret
    if ! kubectl get secrets -n "$NAMESPACE" | grep "$HD_AGENT_POD_RELEASE_NAME-token-secret" > "$DIAGNOSTICS_DIR/secrets.log" 2>&1; then
        echo "ERROR: $HD_AGENT_POD_RELEASE_NAME-token-secret is missing" > "$DIAGNOSTICS_DIR/secrets.log"
        AGENT_POD_CHECKS_PASSED=false
    fi

    # Describe node
    local HD_AGENT_NODE_NAME=$(kubectl get pod "$HD_AGENT_POD_NAME" -n "$NAMESPACE" -o jsonpath="{.spec.nodeName}")
    kubectl describe node "$HD_AGENT_NODE_NAME" > "$DIAGNOSTICS_DIR/node_description.log" 2>&1

    # ServiceAccount
    local SERVICE_ACCOUNTS_LOG_FILE="$DIAGNOSTICS_DIR/service_accounts.log"
    touch "$SERVICE_ACCOUNTS_LOG_FILE"
    echo -n > "$SERVICE_ACCOUNTS_LOG_FILE"
    if ! kubectl get serviceaccount "$HD_AGENT_SA_NAME" -n "$NAMESPACE" >> "$SERVICE_ACCOUNTS_LOG_FILE" 2>&1; then
        echo "ERROR: service account $HD_AGENT_SA_NAME is missing" >> "$SERVICE_ACCOUNTS_LOG_FILE"
        AGENT_POD_CHECKS_PASSED=false
    fi
    if ! kubectl get serviceaccount "$HD_JOB_SA_NAME" -n "$NAMESPACE" >> "$SERVICE_ACCOUNTS_LOG_FILE" 2>&1; then
        echo "ERROR: service account $HD_JOB_SA_NAME is missing" >> "$SERVICE_ACCOUNTS_LOG_FILE"
        AGENT_POD_CHECKS_PASSED=false
    fi
    if kubectl get pod "$HD_AGENT_POD_NAME" -n "$NAMESPACE" -o jsonpath="{.spec.serviceAccountName}" | grep -q "$HD_AGENT_SA_NAME"; then
        echo "Service account $HD_AGENT_SA_NAME is attached to the HD agent pod" >> "$SERVICE_ACCOUNTS_LOG_FILE"
    else
        echo "ERROR: service account $HD_AGENT_SA_NAME is not attached to the HD agent pod" >> "$SERVICE_ACCOUNTS_LOG_FILE"
        AGENT_POD_CHECKS_PASSED=false
    fi

    # Roles
    local ROLES_LOG_FILE="$DIAGNOSTICS_DIR/roles.log"
    touch "$ROLES_LOG_FILE"
    echo -n > "$ROLES_LOG_FILE"
    if ! kubectl get role "$HD_AGENT_ROLE_NAME" -n "$NAMESPACE" >> "$ROLES_LOG_FILE" 2>&1; then
        echo "ERROR: unable to find role $HD_AGENT_ROLE_NAME" >> "$ROLES_LOG_FILE"
        AGENT_POD_CHECKS_PASSED=false
    fi
    if ! kubectl get role "$HD_JOB_ROLE_NAME" -n "$NAMESPACE" >> "$ROLES_LOG_FILE" 2>&1; then
        echo "ERROR: unable to find role $HD_JOB_ROLE_NAME" >> "$ROLES_LOG_FILE"
        AGENT_POD_CHECKS_PASSED=false
    fi
    if ! kubectl get role "$HD_AGENT_EVENT_READER_ROLE_NAME" -n "$NAMESPACE" >> "$ROLES_LOG_FILE" 2>&1; then
        echo "ERROR: unable to find role $HD_AGENT_EVENT_READER_ROLE_NAME" >> "$ROLES_LOG_FILE"
        AGENT_POD_CHECKS_PASSED=false
    fi

    # Role bindings
    local ROLE_BINDINGS_LOG_FILE="$DIAGNOSTICS_DIR/role_bindings.log"
    touch "$ROLE_BINDINGS_LOG_FILE"
    echo -n > "$ROLE_BINDINGS_LOG_FILE"
    if ! kubectl get rolebinding "$HD_AGENT_ROLE_BINDING" -n "$NAMESPACE" >> "$ROLE_BINDINGS_LOG_FILE" 2>&1; then
        echo "ERROR: unable to find rolebinding $HD_AGENT_ROLE_BINDING" >> "$ROLE_BINDINGS_LOG_FILE"
        AGENT_POD_CHECKS_PASSED=false
    fi
    if kubectl get rolebinding "$HD_AGENT_ROLE_BINDING" -n "$NAMESPACE" -o jsonpath="{.subjects[?(@.kind=='ServiceAccount')].name}" | grep -q "$HD_AGENT_SA_NAME"; then
        echo "Service account $HD_AGENT_SA_NAME is bound to $HD_AGENT_ROLE_BINDING" >> "$ROLE_BINDINGS_LOG_FILE"
    else
        echo "ERROR: Service account $HD_AGENT_SA_NAME is not bound to $HD_AGENT_ROLE_BINDING" >> "$ROLE_BINDINGS_LOG_FILE"
        AGENT_POD_CHECKS_PASSED=false
    fi
    if kubectl get rolebinding "$HD_AGENT_ROLE_BINDING" -n "$NAMESPACE" -o jsonpath="{.roleRef.name}" | grep -q "$HD_AGENT_ROLE_NAME"; then
        echo "Role $HD_AGENT_ROLE_NAME is bound to $HD_AGENT_ROLE_BINDING" >> "$ROLE_BINDINGS_LOG_FILE"
    else
        echo "ERROR: Role $HD_AGENT_ROLE_NAME is not bound to $HD_AGENT_ROLE_BINDING" >> "$ROLE_BINDINGS_LOG_FILE"
        AGENT_POD_CHECKS_PASSED=false
    fi

    echo -e "\n" >> "$ROLE_BINDINGS_LOG_FILE"

    if ! kubectl get rolebinding "$HD_JOB_ROLE_BINDING" -n "$NAMESPACE" >> "$ROLE_BINDINGS_LOG_FILE" 2>&1; then
        echo "ERROR: unable to find rolebinding $HD_JOB_ROLE_BINDING" >> "$ROLE_BINDINGS_LOG_FILE"
        AGENT_POD_CHECKS_PASSED=false
    fi
    if kubectl get rolebinding "$HD_JOB_ROLE_BINDING" -n "$NAMESPACE" -o jsonpath="{.subjects[?(@.kind=='ServiceAccount')].name}" | grep -q "$HD_JOB_SA_NAME"; then
        echo "Service account $HD_JOB_SA_NAME is bound to $HD_JOB_ROLE_BINDING" >> "$ROLE_BINDINGS_LOG_FILE"
    else
        echo "ERROR: Service account $HD_AGENT_SA_NAME is not bound to $HD_AGENT_ROLE_BINDING" >> "$ROLE_BINDINGS_LOG_FILE"
        AGENT_POD_CHECKS_PASSED=false
    fi
    if kubectl get rolebinding "$HD_JOB_ROLE_BINDING" -n "$NAMESPACE" -o jsonpath="{.roleRef.name}" | grep -q "$HD_JOB_ROLE_NAME"; then
        echo "Role $HD_JOB_SA_NAME is bound to $HD_AGENT_ROLE_BINDING" >> "$ROLE_BINDINGS_LOG_FILE"
    else
        echo "ERROR: Role $HD_JOB_SA_NAME is not bound to $HD_AGENT_ROLE_BINDING" >> "$ROLE_BINDINGS_LOG_FILE"
        AGENT_POD_CHECKS_PASSED=false
    fi

    echo -e "\n" >> "$ROLE_BINDINGS_LOG_FILE"

    if ! kubectl get rolebinding "$HD_AGENT_EVENT_READER_ROLE_BINDING" -n "$NAMESPACE" >> "$ROLE_BINDINGS_LOG_FILE" 2>&1; then
        echo "ERROR: unable to find rolebinding $HD_AGENT_EVENT_READER_ROLE_BINDING" >> "$ROLE_BINDINGS_LOG_FILE"
        AGENT_POD_CHECKS_PASSED=false
    fi
    if kubectl get rolebinding "$HD_AGENT_EVENT_READER_ROLE_BINDING" -n "$NAMESPACE" -o jsonpath="{.subjects[?(@.kind=='ServiceAccount')].name}" | grep -q "$HD_AGENT_SA_NAME"; then
        echo "Service account $HD_AGENT_SA_NAME is bound to $HD_AGENT_EVENT_READER_ROLE_BINDING" >> "$ROLE_BINDINGS_LOG_FILE"
    else
        echo "ERROR: Service account $HD_AGENT_SA_NAME is not bound to $HD_AGENT_EVENT_READER_ROLE_BINDING" >> "$ROLE_BINDINGS_LOG_FILE"
        AGENT_POD_CHECKS_PASSED=false
    fi
    if kubectl get rolebinding "$HD_AGENT_EVENT_READER_ROLE_BINDING" -n "$NAMESPACE" -o jsonpath="{.roleRef.name}" | grep -q "$HD_AGENT_EVENT_READER_ROLE_NAME"; then
        echo "Role $HD_AGENT_EVENT_READER_ROLE_NAME is bound to $HD_AGENT_EVENT_READER_ROLE_BINDING" >> "$ROLE_BINDINGS_LOG_FILE"
    else
        echo "ERROR: Role $HD_AGENT_EVENT_READER_ROLE_NAME is not bound to $HD_AGENT_ROLE_BINDING" >> "$ROLE_BINDINGS_LOG_FILE"
        AGENT_POD_CHECKS_PASSED=false
    fi

    if [ "$AGENT_POD_CHECKS_PASSED" = true ]; then
        echo "OK"
    else
        echo "FAILED"
    fi
}

ENDPOINT_REACHABILITY_LOG_FILE="$DIAGNOSTICS_DIR/endpoint_reachability.log"

function check_endpoints_reachability() {

    CONNECT_TIMEOUT=30

    echo -n "Logging endpoint reachability..."

    touch "$ENDPOINT_REACHABILITY_LOG_FILE"
    echo -n > "$ENDPOINT_REACHABILITY_LOG_FILE"

    local ENDPOINT_CHECKS_PASSED=true

    if [ "$(kubectl get pod "$UTIL_POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null)" != "Running" ]; then
        echo "Utility pod is not running. Cannot perform endpoint checks." >> "$ENDPOINT_REACHABILITY_LOG_FILE"
        echo $(kubectl get pod "$UTIL_POD_NAME" -n "$NAMESPACE" -o yaml) >> "$ENDPOINT_REACHABILITY_LOG_FILE"
        echo "FAILED"
        return
    fi

    for url in "${ENDPOINTS[@]}"; do
        if kubectl exec --namespace="$NAMESPACE" "$UTIL_POD_NAME" -- \
          curl -s -o /dev/null --connect-timeout "${CONNECT_TIMEOUT}" --max-time "${CONNECT_TIMEOUT}" --retry 3 --retry-delay 2 "$url"; then
            echo "Endpoint is reachable -> $url" >> "$ENDPOINT_REACHABILITY_LOG_FILE"
        else
            echo "ERROR: unable to reach endpoint: $url" >> "$ENDPOINT_REACHABILITY_LOG_FILE"
            ENDPOINT_CHECKS_PASSED=false
        fi
    done

    if [ "$ENDPOINT_CHECKS_PASSED" = true ]; then
        echo "OK"
    else
        echo "FAILED"
    fi
}

function check_pvc_write_access() {
    if ! [ -n "$PVC_NAME" ]; then
      return
    fi
    echo -n "Executing PVC write test..."

    if [ "$(kubectl get pod "$UTIL_POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null)" != "Running" ]; then
        echo "FAILED"
        echo "Utility pod is not running. Cannot perform PVC write test." >> "$PVC_LOG_FILE"
        return
    fi

    local TEST_FILE="test_write_$(date +%Y%m%d%H%M%S).txt"
    local TEST_CONTENT="PVC test on $(date) $RANDOM"

    # Command to run inside the pod
    local EXEC_CMD="echo '${TEST_CONTENT}' > ${PVC_MOUNT_PATH}/${TEST_FILE}; \
              cat ${PVC_MOUNT_PATH}/${TEST_FILE}; \
              rm ${PVC_MOUNT_PATH}/${TEST_FILE} || \
              (echo 'Error during test execution' && exit 1)"

    local EXEC_OUTPUT=$(kubectl exec -n "$NAMESPACE" "$UTIL_POD_NAME" -- /bin/sh -c "$EXEC_CMD" 2>&1)
    local EXEC_STATUS=$?

    if [ "$EXEC_STATUS" -eq 0 ] && \
       echo "$EXEC_OUTPUT" | grep -q "$TEST_CONTENT"; then
        echo "PVC write test succeeded." >> "$PVC_LOG_FILE"
        echo "OK"
    else
        echo "PVC write test failed." >> "$PVC_LOG_FILE"
        echo "$EXEC_OUTPUT" >> "$PVC_LOG_FILE"
        echo "FAILED"
    fi
}

check_agent_pod
if create_and_wait_utility_pod 2>&1; then
	  check_endpoints_reachability
	  check_pvc_write_access
else
	  echo "Utility pod not available, skipping endpoint reachability checks." > "$ENDPOINT_REACHABILITY_LOG_FILE"
	  echo "Utility pod not available, skipping PVC write test" > "$PVC_LOG_FILE"
	  echo
	  echo "Please check kubectl permissions or cluster status."
fi

(cd "$DIAGNOSTICS_DIR" && tar -czf "$ARCHIVE_PATH" *.log)

cleanup_utility_pod

echo -e "\nLogs are available in $ARCHIVE_PATH"
