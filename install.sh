#!/bin/bash
#
#  Installer for Fivetran Hybrid Deployment Agent on Linux using 
#  containers (docker or podman)
# 
#  For more information: 
#     https://github.com/fivetran/hybrid_deployment
#     https://fivetran.com/docs/core-concepts/architecture/hybrid-deployment
#
# set -x
set -e

if [ "$UID" -eq 0 ]; then
  echo "This script should not be run as root. Please run as a regular user."
  exit 1
fi

if [ -z "$RUNTIME" ]; then
  echo "Error: No runtime specified. Please set the RUNTIME environment variable."
  exit 1
fi

if [[ "$RUNTIME" != "docker" && "$RUNTIME" != "podman" ]]; then
  echo "Error: Invalid runtime specified. Please use 'docker' or 'podman'."
  exit 1
fi

# ensure valid token provided as environment variable (TOKEN)
if [[ -n $TOKEN ]]; then 
    CONTROLLER_ID=$(echo $TOKEN | base64 -d | cut -f1 -d":")
    if [ $? -ne 0 ] || [[ ! "$CONTROLLER_ID" =~ ^[a-zA-Z]+_[a-zA-Z]+$ ]]; then
        echo "Invalid TOKEN provided."
        exit 1
    fi
else
    echo "No TOKEN value specified"
    exit 1
fi

echo -e "Installing Hybrid Deployment Agent...\n"

# Default install location is $HOME/fivetran
BASE_DIR=$HOME/fivetran

AGENT_URL="https://raw.githubusercontent.com/fivetran/hybrid_deployment/main/hdagent.sh"
AGENT_SCRIPT=hdagent.sh
CONFIG_FILE=$BASE_DIR/conf/config.json
CWD=$(pwd)

if [[ -d "$BASE_DIR" ]]; then
    echo "$BASE_DIR already exist, will re-use it."
else
    mkdir -p $BASE_DIR
fi

if [[ ! -w $BASE_DIR ]]; then
    echo -e "Insufficient permissions to write to $BASE_DIR"
    exit 1
fi

cd $BASE_DIR
mkdir -p data tmp logs conf

set +e
curl -s -f -o $AGENT_SCRIPT $AGENT_URL || {
    echo "Unable to download the file $AGENT_SCRIPT from $AGENT_URL"
    exit 1
}
set -e
chmod u+x $AGENT_SCRIPT

if [[ -f "./config.json" ]]; then
     # upgrade old config files to new path
     echo -e "Moving existing config.json to conf/"
     mv -v ./config.json ./conf/
fi

if [[ -f "$CONFIG_FILE" ]]; then
    if grep -q '"token": *"[^"]*"' "$CONFIG_FILE"; then
       echo "Token found in $CONFIG_FILE and will be reused"
    else
       # add token to existing config file if it does not exist.
       sed -i 's/{/{\n  "token": "'"$TOKEN"'",/' "$CONFIG_FILE"
    fi
else
    # Default new setup, create base config with token
    cat > "$CONFIG_FILE" <<EOF
{
  "token": "$TOKEN"
}
EOF
fi

# Start the agent
./$AGENT_SCRIPT -r $RUNTIME start
if [ $? -ne 0 ]; then
  echo "Installation complete, but agent failed to start."
  echo "Please review the agent container logs for more detail."
  exit 1
fi

cd $CWD

echo -e "Installation complete.\n"
