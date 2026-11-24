#!/usr/bin/env bash

# ==============================================================================
# IPFIX Log Management
#
# Displays logs for all IPFIX pipeline components.
#
# Usage:
#   ./health-check/logs.sh all
#   ./health-check/logs.sh consumer
#   ./health-check/logs.sh goflow2
#   ./health-check/logs.sh kafka
#   ./health-check/logs.sh postgres
#   ./health-check/logs.sh topic [topic-name] [kafka-consumer-options]
#
# Options:
#   --tail <number>   Number of recent log lines (default: 500)
#   --follow          Stream logs continuously
#   --previous       Show logs from previous container instance
#   --help            Display usage information
#
# Kafka topic examples:
#   ./health-check/logs.sh topic
#   ./health-check/logs.sh topic ipfix-bng-1 --from-beginning
#   ./health-check/logs.sh topic ipfix-bng-1 --max-messages 100
# ==============================================================================

set -uo pipefail

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------

NAMESPACE="${IPFIX_NAMESPACE:-nok-ipfix}"
KUBECTL="${KUBECTL:-kubectl}"

CONSUMER_DEPLOYMENT="${IPFIX_CONSUMER_DEPLOYMENT:-ipfix-consumer}"
KAFKA_STATEFULSET="${IPFIX_KAFKA_STATEFULSET:-kafka}"
KAFKA_BROKER="${IPFIX_KAFKA_BROKER:-kafka.nok-ipfix.svc.cluster.local:9092}"
POSTGRES_STATEFULSET="${IPFIX_POSTGRES_STATEFULSET:-ipfix-postgres}"

# Every generated GoFlow2 Deployment has this label.
# Selecting the label key without a value discovers all cluster instances.
GOFLOW_LABEL_SELECTOR="${IPFIX_GOFLOW_LABEL_SELECTOR:-ipfix.cluster}"

DEFAULT_TAIL=500

TAIL="$DEFAULT_TAIL"
FOLLOW=false
PREVIOUS=false
COMPONENT=""

# ------------------------------------------------------------------------------
# Usage
# ------------------------------------------------------------------------------

usage() {
    cat <<EOF

============================================================
 IPFIX: Log Management
============================================================

Usage:
  $0 <component> [options]

Components:
  all         All IPFIX components
  consumer    Kafka-to-PostgreSQL consumer
  goflow2     All GoFlow2 collectors
  kafka       Kafka broker
  postgres    PostgreSQL database

Options:
  --tail N    Number of recent log lines (default: 500)
  --follow    Follow logs continuously
  --previous  Show previous container logs
  --help      Display this help message

Examples:
  $0 all
  $0 all --tail 1000
  $0 consumer --follow
  $0 goflow2 --tail 500
  $0 goflow2 --follow
  $0 consumer --previous
  $0 kafka --follow

Environment:
  IPFIX_NAMESPACE               Kubernetes namespace (default: nok-ipfix)
  KUBECTL                       kubectl executable (default: kubectl)
  IPFIX_CONSUMER_DEPLOYMENT     Consumer Deployment name
  IPFIX_KAFKA_STATEFULSET       Kafka StatefulSet name
  IPFIX_POSTGRES_STATEFULSET    PostgreSQL StatefulSet name
  IPFIX_GOFLOW_LABEL_SELECTOR   GoFlow2 Deployment label selector

============================================================

EOF
}

# ------------------------------------------------------------------------------
# Argument Parsing
# ------------------------------------------------------------------------------

if [[ $# -eq 0 ]]; then
    usage
    exit 1
fi

COMPONENT="$1"
shift

TOPIC_ARGS=()

if [[ "$COMPONENT" == "topic" ]]; then
    TOPIC_NAME=""

    if [[ $# -gt 0 && "$1" != --* ]]; then
        TOPIC_NAME="$1"
        shift
    fi

    # All remaining arguments are passed directly
    # to kafka-console-consumer.sh.
    TOPIC_ARGS=("$TOPIC_NAME" "$@")
    set --
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tail)
            if [[ $# -lt 2 || ! "$2" =~ ^[1-9][0-9]*$ ]]; then
                echo "[ERROR] --tail requires a positive integer."
                exit 1
            fi
            TAIL="$2"
            shift 2
            ;;

        --follow)
            FOLLOW=true
            shift
            ;;

        --previous)
            PREVIOUS=true
            shift
            ;;

        --help|-h)
            usage
            exit 0
            ;;

        *)
            echo "[ERROR] Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# ------------------------------------------------------------------------------
# Validation
# ------------------------------------------------------------------------------

case "$COMPONENT" in
    all|consumer|goflow2|kafka|postgres|topic)
        ;;
    *)
        echo "[ERROR] Invalid component: $COMPONENT"
        usage
        exit 1
        ;;
esac

if [[ "$FOLLOW" == true && "$PREVIOUS" == true ]]; then
    echo "[ERROR] --follow and --previous cannot be used together."
    exit 1
fi

if ! command -v "$KUBECTL" >/dev/null 2>&1; then
    echo "[ERROR] kubectl command not found: $KUBECTL"
    exit 1
fi

if ! "$KUBECTL" get namespace "$NAMESPACE" >/dev/null 2>&1; then
    echo "[ERROR] Kubernetes namespace not found: $NAMESPACE"
    exit 1
fi

# ------------------------------------------------------------------------------
# GoFlow2 Deployment Discovery
# ------------------------------------------------------------------------------

get_goflow2_deployments() {
    "$KUBECTL" get deployments \
        -n "$NAMESPACE" \
        -l "$GOFLOW_LABEL_SELECTOR" \
        -o name 2>/dev/null
}

# ------------------------------------------------------------------------------
# Log Display
# ------------------------------------------------------------------------------

show_logs() {
    local resource="$1"
    local description="$2"

    echo ""
    echo "============================================================"
    echo " $description"
    echo " Resource: $resource"
    echo " Namespace: $NAMESPACE"
    echo " Tail: $TAIL"
    echo "============================================================"

    local args=(
        logs
        "$resource"
        -n "$NAMESPACE"
        "--tail=$TAIL"
        --all-containers=true
        --prefix=true
    )

    if [[ "$PREVIOUS" == true ]]; then
        args+=(--previous)
    fi

    if [[ "$FOLLOW" == true ]]; then
        args+=(--follow)
    fi

    "$KUBECTL" "${args[@]}"
}

# ------------------------------------------------------------------------------
# Component Handlers
# ------------------------------------------------------------------------------

show_consumer() {
    show_logs \
        "deployment/$CONSUMER_DEPLOYMENT" \
        "IPFIX CONSUMER"
}

show_goflow2() {
    local deployments
    local count=0
    local failed=0

    deployments="$(get_goflow2_deployments)" || {
        echo "[ERROR] Failed to discover GoFlow2 deployments."
        return 1
    }

    if [[ -z "$deployments" ]]; then
        echo "[WARN] No GoFlow2 deployments found using label:"
        echo "       $GOFLOW_LABEL_SELECTOR"
        return 1
    fi

    # Follow all GoFlow2 instances concurrently.
    if [[ "$FOLLOW" == true ]]; then
        local resources=()

        while IFS= read -r deployment; do
            [[ -z "$deployment" ]] && continue
            resources+=("$deployment")
        done <<< "$deployments"

        follow_resources "${resources[@]}"
        return $?
    fi

    # Display logs from each GoFlow2 instance sequentially.
    while IFS= read -r deployment; do
        [[ -z "$deployment" ]] && continue

        show_logs "$deployment" "GOFLOW2 COLLECTOR: $deployment"
        local rc=$?

        if [[ $rc -ne 0 ]]; then
            echo "[WARN] Failed to retrieve logs: $deployment"
            failed=1
        fi

        count=$((count + 1))

    done <<< "$deployments"

    echo ""
    echo "[INFO] GoFlow2 deployments discovered: $count"

    return "$failed"
}

show_kafka() {
    show_logs \
        "statefulset/$KAFKA_STATEFULSET" \
        "KAFKA BROKER"
}

show_kafka_topic() {
    local topic="${1:-}"
    shift || true

    if [[ -z "$topic" ]]; then
        echo ""
        read -r -p "Enter Kafka topic name: " topic
    fi

    if [[ -z "$topic" ]]; then
        echo "[ERROR] Kafka topic name cannot be empty."
        return 1
    fi

    echo ""
    echo "============================================================"
    echo " KAFKA TOPIC: $topic"
    echo " Namespace: $NAMESPACE"
    echo " Broker: $KAFKA_BROKER"
    echo "============================================================"

    "$KUBECTL" exec -i \
        -n "$NAMESPACE" \
        "statefulset/$KAFKA_STATEFULSET" \
        -- /opt/kafka/bin/kafka-console-consumer.sh \
        --bootstrap-server "$KAFKA_BROKER" \
        --topic "$topic" \
        "$@"
}


show_postgres() {
    show_logs \
        "statefulset/$POSTGRES_STATEFULSET" \
        "POSTGRESQL DATABASE"
}

# ------------------------------------------------------------------------------
# Follow Multiple Resources Concurrently
# ------------------------------------------------------------------------------

follow_resources() {
    local resources=("$@")
    local pids=()
    local resource
    local pid

    if [[ ${#resources[@]} -eq 0 ]]; then
        echo "[WARN] No resources available for log streaming."
        return 1
    fi

    cleanup() {
        echo ""
        echo "[INFO] Stopping log streams..."

        for pid in "${pids[@]}"; do
            kill "$pid" 2>/dev/null || true
        done

        for pid in "${pids[@]}"; do
            wait "$pid" 2>/dev/null || true
        done
    }

    trap cleanup INT TERM

    echo ""
    echo "============================================================"
    echo " IPFIX: Following component logs"
    echo " Namespace: $NAMESPACE"
    echo " Tail: $TAIL"
    echo " Resources: ${#resources[@]}"
    echo "============================================================"

    for resource in "${resources[@]}"; do
        (
            echo ""
            echo "========== $resource =========="

            "$KUBECTL" logs "$resource" \
                -n "$NAMESPACE" \
                "--tail=$TAIL" \
                --all-containers=true \
                --prefix=true \
                --follow
        ) &

        pids+=("$!")
    done

    echo ""
    echo "[INFO] Streaming logs. Press Ctrl+C to stop."

    # Wait for all streams. A stream may exit if its resource fails.
    local failed=0

    for pid in "${pids[@]}"; do
        wait "$pid" || failed=1
    done

    trap - INT TERM

    return "$failed"
}

# ------------------------------------------------------------------------------
# Follow All Components Concurrently
# ------------------------------------------------------------------------------

follow_all() {
    local resources=(
        "deployment/$CONSUMER_DEPLOYMENT"
        "statefulset/$KAFKA_STATEFULSET"
        "statefulset/$POSTGRES_STATEFULSET"
    )

    local goflow_deployments

    goflow_deployments="$(get_goflow2_deployments)" || {
        echo "[ERROR] Failed to discover GoFlow2 deployments."
        return 1
    }

    while IFS= read -r deployment; do
        [[ -z "$deployment" ]] && continue
        resources+=("$deployment")
    done <<< "$goflow_deployments"

    follow_resources "${resources[@]}"
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

echo ""
echo "============================================================"
echo " IPFIX: Log Management"
echo " Component: $COMPONENT"
echo " Namespace: $NAMESPACE"
echo "============================================================"

if [[ "$COMPONENT" == "all" && "$FOLLOW" == true ]]; then
    follow_all
    exit $?
fi

case "$COMPONENT" in

    all)
        show_consumer || true
        show_goflow2 || true
        show_kafka || true
        show_postgres || true
        ;;

    consumer)
        show_consumer
        ;;

    goflow2)
        show_goflow2
        ;;

    kafka)
        show_kafka
        ;;

    postgres)
        show_postgres
        ;;
    
    topic)
        show_kafka_topic "${TOPIC_ARGS[@]}"
        ;;

esac

echo ""
echo "============================================================"
echo " IPFIX: Log retrieval completed"
echo "============================================================"
