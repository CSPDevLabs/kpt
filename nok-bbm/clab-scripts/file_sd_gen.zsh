#!/usr/bin/zsh

### Check number of arcguments
if [[ $# -ne 2 ]]; then
    echo "Error: This script requires exactly 2 arguments."
    echo "Usage: $0 <clab_name> <clab_node_kind>"
    exit 1
fi

CLAB_NAME="$1"
SELECTED_KIND="$2"
CM_NAME=$(echo -n ${SELECTED_KIND}-${CLAB_NAME} | sed -e 's/_/-/g')
TEMP_OUT_FILE=/tmp/${0}-$(uuidgen)

PAYLOAD=`clab inspect -w --name $CLAB_NAME --details 2> /dev/null | jq --arg target_kind "$SELECTED_KIND" '[ .sros_bngt[] | select(.Labels["clab-node-kind"] == $target_kind) | {targets: [.NetworkSettings.IPv4addr], labels: {hostname: .Names[0], kind: .Labels["clab-node-kind"]}} ]'`

# Need to ident
INDENTED_PAYLOAD=$(echo "$PAYLOAD" | sed 's/^/    /')

# Output the ConfigMap 
cat <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${CM_NAME}
  labels:
    app: bbm-prometheus
  namespace: nok-bbm
data:
  ${SELECTED_KIND}-${CLAB_NAME}.json: |
$INDENTED_PAYLOAD
EOF