#!/usr/bin/env bash

# ==============================================================================
# GoFlow2 & Kafka Manifest Generator
#
# Generates cluster-specific GoFlow2 and Kafka manifests using clusters.conf.
#
# - Generates manifests for newly configured clusters.
# - Preserves existing manifests without modification or recreation.
# - Regenerates missing manifests for clusters still present in the config.
# - Warns about existing manifests whose clusters are no longer configured.
# - Never automatically deletes existing manifests.
#
# Configuration (clusters.conf):
#   cluster_id|load_balancer_ip|kafka_partitions
#
# Generated resources:
#   Kafka topic:       ipfix-${cluster_id}
#   GoFlow2:           goflow-${cluster_id}
#   Kafka Job:         kafka-create-topic-ipfix-${cluster_id}
#
# ==============================================================================

set -Eeuo pipefail

# ------------------------------------------------------------------------------
# Paths and fixed configuration
# ------------------------------------------------------------------------------

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
IPFIX_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

CONFIG_FILE="${1:-${IPFIX_DIR}/clusters.conf}"

GOFLOW_TEMPLATE_DIR="${IPFIX_DIR}/goflow/templates"
KAFKA_TEMPLATE_DIR="${IPFIX_DIR}/kafka/templates"
GOFLOW_OUTPUT_DIR="${IPFIX_DIR}/goflow"
KAFKA_OUTPUT_DIR="${IPFIX_DIR}/kafka"

NAMESPACE="nok-ipfix"
KAFKA_BROKER="kafka.nok-ipfix.svc.cluster.local:9092"
KAFKA_IMAGE="apache/kafka:4.1.0"
GOFLOW_IMAGE="ghcr.io/netsampler/goflow2:v2"
KAFKA_REPLICATION_FACTOR=1

# ------------------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------------------

log() {
    printf '[INFO] %s\n' "$*"
}

success() {
    printf '[SUCCESS] %s\n' "$*"
}

warning() {
    printf '[WARNING] %s\n' "$*" >&2
}

error() {
    printf '[ERROR] %s\n' "$*" >&2
}

die() {
    error "$*"
    exit 1
}

# ------------------------------------------------------------------------------
# Validation
# ------------------------------------------------------------------------------

# Kubernetes resource naming:
# The longest generated resource name is:
# kafka-create-topic-ipfix-${cluster_id}
#
# Prefix length = 25
# Kubernetes DNS label maximum = 63
# Therefore cluster_id maximum = 38 characters.

validate_cluster_id() {
    local cluster_id="$1"

    [[ "$cluster_id" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1

    (( ${#cluster_id} <= 38 ))
}

validate_ipv4() {
    local ip="$1"
    local octet
    local -a octets

    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1

    IFS='.' read -r -a octets <<< "$ip"

    (( ${#octets[@]} == 4 )) || return 1

    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^(0|[1-9][0-9]{0,2})$ ]] || return 1
        (( 10#$octet <= 255 )) || return 1
    done

    local first="${octets[0]}"
    local second="${octets[1]}"

    # Reject unspecified and reserved first octets.
    (( 10#$first >= 1 && 10#$first <= 223 )) || return 1

    # Reject loopback addresses.
    (( 10#$first != 127 )) || return 1

    # Reject link-local addresses.
    if (( 10#$first == 169 && 10#$second == 254 )); then
        return 1
    fi

    # Reject limited broadcast.
    [[ "$ip" != "255.255.255.255" ]] || return 1
}

validate_positive_integer() {
    local value="$1"

    [[ "$value" =~ ^[0-9]+$ ]] || return 1

    # Remove leading zeros before arithmetic comparison.
    local normalized="${value#"${value%%[!0]*}"}"
    normalized="${normalized:-0}"

    # Kafka partition count must be positive and fit a signed 32-bit integer.
    (( ${#normalized} <= 10 )) || return 1
    (( 10#$normalized > 0 && 10#$normalized <= 2147483647 ))
}

validate_template() {
    [[ -f "$1" && -r "$1" ]] || die "Template missing or unreadable: $1"
}

# ------------------------------------------------------------------------------
# Template rendering
# ------------------------------------------------------------------------------

render_template() {
    local template_file="$1"
    local output_file="$2"
    local cluster_id="$3"
    local topic="$4"
    local goflow_name="$5"
    local load_balancer_ip="$6"
    local kafka_partitions="$7"

    local content

    content="$(<"$template_file")"

    content="${content//\$\{CLUSTER_ID\}/$cluster_id}"
    content="${content//\$\{TOPIC\}/$topic}"
    content="${content//\$\{GOFLOW_NAME\}/$goflow_name}"
    content="${content//\$\{APP_LABEL\}/$goflow_name}"
    content="${content//\$\{LOAD_BALANCER_IP\}/$load_balancer_ip}"

    content="${content//\$\{NAMESPACE\}/$NAMESPACE}"
    content="${content//\$\{KAFKA_BROKER\}/$KAFKA_BROKER}"
    content="${content//\$\{KAFKA_IMAGE\}/$KAFKA_IMAGE}"
    content="${content//\$\{GOFLOW_IMAGE\}/$GOFLOW_IMAGE}"

    content="${content//\$\{KAFKA_PARTITIONS\}/$kafka_partitions}"

    # Detect unresolved placeholders anywhere in the manifest.
    if grep -Eq '\$\{[A-Z_]+\}' <<< "$content"; then
        die "Unresolved placeholder in template: ${template_file}"
    fi

    printf '%s\n' "$content" > "$output_file"
}

# ------------------------------------------------------------------------------
# Generate manifest only when it does not already exist.
# ------------------------------------------------------------------------------

generate_if_missing() {
    local template_file="$1"
    local output_file="$2"
    local cluster_id="$3"
    local topic="$4"
    local goflow_name="$5"
    local load_balancer_ip="$6"
    local kafka_partitions="$7"

    if [[ -f "$output_file" ]]; then
        log "Manifest already exists. Skipping without modification: $(basename "$output_file")"
        return 0
    fi

    render_template \
        "$template_file" \
        "$output_file" \
        "$cluster_id" \
        "$topic" \
        "$goflow_name" \
        "$load_balancer_ip" \
        "$kafka_partitions"

    success "Generated manifest: $(basename "$output_file")"
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

main() {

    log "Starting Nokia IPFIX manifest generation"

    [[ -f "$CONFIG_FILE" ]] || die "Configuration not found: $CONFIG_FILE"

    validate_template "${GOFLOW_TEMPLATE_DIR}/deployment.yaml.tmpl"
    validate_template "${GOFLOW_TEMPLATE_DIR}/service.yaml.tmpl"
    validate_template "${KAFKA_TEMPLATE_DIR}/topic-job.yaml.tmpl"

    mkdir -p "$GOFLOW_OUTPUT_DIR" "$KAFKA_OUTPUT_DIR"

    local -a cluster_ids=()
    local -a load_balancer_ips=()
    local -a kafka_partitions_list=()

    local line
    local cluster_id
    local load_balancer_ip
    local kafka_partitions
    local line_number=0
    local cluster_count=0
    local pipe_count

    declare -A seen_clusters=()
    declare -A seen_ips=()

    # --------------------------------------------------------------------------
    # Read and validate all configuration before generating manifests.
    # --------------------------------------------------------------------------

    while IFS= read -r line || [[ -n "$line" ]]; do

        line_number=$((line_number + 1))

        # Remove Windows carriage returns.
        line="${line%$'\r'}"

        # Ignore empty lines and comments.
        [[ -z "${line//[[:space:]]/}" ]] && continue

        line="${line#"${line%%[![:space:]]*}"}"
        [[ "$line" == \#* ]] && continue

        # Require exactly three fields (two separators).
        pipe_count="${line//[^|]/}"

        [[ ${#pipe_count} -eq 2 ]] ||
            die "Invalid configuration at line ${line_number}: expected cluster_id|load_balancer_ip|kafka_partitions"

        IFS='|' read -r \
            cluster_id \
            load_balancer_ip \
            kafka_partitions <<< "$line"

        # Trim whitespace from each field.
        cluster_id="${cluster_id#"${cluster_id%%[![:space:]]*}"}"
        cluster_id="${cluster_id%"${cluster_id##*[![:space:]]}"}"

        load_balancer_ip="${load_balancer_ip#"${load_balancer_ip%%[![:space:]]*}"}"
        load_balancer_ip="${load_balancer_ip%"${load_balancer_ip##*[![:space:]]}"}"

        kafka_partitions="${kafka_partitions#"${kafka_partitions%%[![:space:]]*}"}"
        kafka_partitions="${kafka_partitions%"${kafka_partitions##*[![:space:]]}"}"

        [[ -n "$cluster_id" ]] ||
            die "Missing cluster_id at line ${line_number}"

        [[ -n "$load_balancer_ip" ]] ||
            die "Missing LoadBalancer IP at line ${line_number}"

        [[ -n "$kafka_partitions" ]] ||
            die "Missing Kafka partitions at line ${line_number}"

        validate_cluster_id "$cluster_id" ||
            die "Invalid cluster_id '${cluster_id}' at line ${line_number}"

        validate_ipv4 "$load_balancer_ip" ||
            die "Invalid IPv4 address '${load_balancer_ip}' at line ${line_number}"

        validate_positive_integer "$kafka_partitions" ||
            die "Invalid Kafka partitions '${kafka_partitions}' at line ${line_number}"

        [[ -z "${seen_clusters[$cluster_id]+x}" ]] ||
            die "Duplicate cluster_id: ${cluster_id}"

        [[ -z "${seen_ips[$load_balancer_ip]+x}" ]] ||
            die "Duplicate LoadBalancer IP: ${load_balancer_ip}"

        seen_clusters["$cluster_id"]=1
        seen_ips["$load_balancer_ip"]=1

        cluster_ids+=("$cluster_id")
        load_balancer_ips+=("$load_balancer_ip")
        kafka_partitions_list+=("$kafka_partitions")

        cluster_count=$((cluster_count + 1))

    done < "$CONFIG_FILE"

    (( cluster_count > 0 )) ||
        die "No valid clusters configured in ${CONFIG_FILE}"

    log "Validated ${cluster_count} cluster(s)"
    log "Kafka replication factor: ${KAFKA_REPLICATION_FACTOR}"

    # --------------------------------------------------------------------------
    # Generate manifests.
    # Existing manifests are preserved without modification.
    # --------------------------------------------------------------------------

    local topic
    local goflow_name
    local deployment_file
    local service_file
    local topic_file
    local i

    for ((i = 0; i < cluster_count; i++)); do

        cluster_id="${cluster_ids[$i]}"
        load_balancer_ip="${load_balancer_ips[$i]}"
        kafka_partitions="${kafka_partitions_list[$i]}"

        topic="ipfix-${cluster_id}"
        goflow_name="goflow-${cluster_id}"

        deployment_file="${GOFLOW_OUTPUT_DIR}/deployment-${cluster_id}.yaml"
        service_file="${GOFLOW_OUTPUT_DIR}/service-${cluster_id}.yaml"
        topic_file="${KAFKA_OUTPUT_DIR}/topic-${topic}.yaml"

        log "Processing manifests for cluster: ${cluster_id}"

        generate_if_missing \
            "${GOFLOW_TEMPLATE_DIR}/deployment.yaml.tmpl" \
            "$deployment_file" \
            "$cluster_id" "$topic" "$goflow_name" "$load_balancer_ip" \
            "$kafka_partitions"

        generate_if_missing \
            "${GOFLOW_TEMPLATE_DIR}/service.yaml.tmpl" \
            "$service_file" \
            "$cluster_id" "$topic" "$goflow_name" "$load_balancer_ip" \
            "$kafka_partitions"

        generate_if_missing \
            "${KAFKA_TEMPLATE_DIR}/topic-job.yaml.tmpl" \
            "$topic_file" \
            "$cluster_id" "$topic" "$goflow_name" "$load_balancer_ip" \
            "$kafka_partitions"

    done

    # --------------------------------------------------------------------------
    # Warn about manifests belonging to clusters absent from clusters.conf.
    # Do not delete or modify these files.
    # --------------------------------------------------------------------------

    local file
    local filename
    local cluster

    for file in \
        "$GOFLOW_OUTPUT_DIR"/deployment-*.yaml \
        "$GOFLOW_OUTPUT_DIR"/service-*.yaml \
        "$KAFKA_OUTPUT_DIR"/topic-ipfix-*.yaml; do

        [[ -f "$file" ]] || continue

        filename="$(basename "$file")"

        # DLQ topic is a permanent manifest, not a cluster-generated file.
        # Never warn about or modify it.
        if [[ "$filename" == "topic-ipfix-dlq.yaml" ]]; then
            log "Preserving reserved DLQ manifest: ${filename}"
            continue
        fi

        cluster=""

        case "$filename" in
            deployment-*.yaml)
                cluster="${filename#deployment-}"
                cluster="${cluster%.yaml}"
                ;;
            service-*.yaml)
                cluster="${filename#service-}"
                cluster="${cluster%.yaml}"
                ;;
            topic-ipfix-*.yaml)
                cluster="${filename#topic-ipfix-}"
                cluster="${cluster%.yaml}"
                ;;
        esac

        if [[ -z "${seen_clusters[$cluster]+x}" ]]; then
            warning "Manifest '${filename}' exists, but cluster '${cluster}' is not configured in clusters.conf. Preserving the file."
        fi
    done

    # --------------------------------------------------------------------------
    # Summary
    # --------------------------------------------------------------------------

    echo ""
    echo "============================================================"
    echo " Nokia IPFIX Manifest Generation Completed"
    echo "============================================================"
    echo " Clusters             : ${cluster_count}"
    echo " GoFlow2 Deployments  : ${cluster_count}"
    echo " GoFlow2 Services     : ${cluster_count}"
    echo " Kafka Topic Jobs     : ${cluster_count}"
    echo " Kafka Replication    : ${KAFKA_REPLICATION_FACTOR}"
    echo "============================================================"
    echo ""

    success "Manifest generation completed successfully"
}

main "$@"
