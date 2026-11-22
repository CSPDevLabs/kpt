#!/usr/bin/env bash

# ==============================================================================
# IPFIX Deployment Health Check
#
# Checks the health/readiness of the base IPFIX deployment.
# This script does NOT generate traffic or verify end-to-end record delivery.
#
# Usage:
#   ./health-check/healthcheck.sh
#
# Environment:
#   IPFIX_NAMESPACE                 Kubernetes namespace (default: nok-ipfix)
#   KUBECTL                         kubectl executable (default: kubectl)
#   IPFIX_CONFIG_FILE               Cluster configuration file
#   IPFIX_CONSUMER_DEPLOYMENT       Consumer Deployment name
#   IPFIX_KAFKA_STATEFULSET         Kafka StatefulSet name
#   IPFIX_POSTGRES_STATEFULSET      PostgreSQL StatefulSet name
#   IPFIX_SCHEMA_TABLE              PostgreSQL table to verify
#   IPFIX_KAFKA_BROKER              Kafka bootstrap server
#   IPFIX_KAFKA_READY_TIMEOUT       StatefulSet/Deployment rollout timeout
#   IPFIX_KAFKA_SERVICE             Kafka Service name
#   IPFIX_POSTGRES_SERVICE          PostgreSQL client Service name
#   IPFIX_POSTGRES_HEADLESS_SERVICE PostgreSQL headless Service name
#
# Exit status:
#   0  All critical checks passed
#   1  One or more critical checks failed
# ==============================================================================

set -uo pipefail

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
IPFIX_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

NAMESPACE="${IPFIX_NAMESPACE:-nok-ipfix}"
KUBECTL="${KUBECTL:-kubectl}"

CONFIG_FILE="${IPFIX_CONFIG_FILE:-$IPFIX_DIR/clusters.conf}"

CONSUMER_DEPLOYMENT="${IPFIX_CONSUMER_DEPLOYMENT:-ipfix-consumer}"
KAFKA_STATEFULSET="${IPFIX_KAFKA_STATEFULSET:-kafka}"
POSTGRES_STATEFULSET="${IPFIX_POSTGRES_STATEFULSET:-ipfix-postgres}"

KAFKA_SERVICE="${IPFIX_KAFKA_SERVICE:-kafka}"
POSTGRES_SERVICE="${IPFIX_POSTGRES_SERVICE:-ipfix-postgres}"
POSTGRES_HEADLESS_SERVICE="${IPFIX_POSTGRES_HEADLESS_SERVICE:-ipfix-postgres-headless}"

KAFKA_BROKER="${IPFIX_KAFKA_BROKER:-kafka.${NAMESPACE}.svc.cluster.local:9092}"
KAFKA_READY_TIMEOUT="${IPFIX_KAFKA_READY_TIMEOUT:-180s}"

SCHEMA_TABLE="${IPFIX_SCHEMA_TABLE:-ipfix_flows}"
DLQ_TOPIC="${IPFIX_KAFKA_DLQ_TOPIC:-ipfix-dlq}"

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

# ------------------------------------------------------------------------------
# Output helpers
# ------------------------------------------------------------------------------

pass() {
    echo "[PASS] $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    echo "[FAIL] $1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

warn() {
    echo "[WARN] $1"
    WARN_COUNT=$((WARN_COUNT + 1))
}

info() {
    echo "[INFO] $1"
}

# ------------------------------------------------------------------------------
# Kubernetes helpers
# ------------------------------------------------------------------------------

resource_exists() {
    local resource="$1"
    local name="$2"

    "$KUBECTL" get "$resource" "$name" \
        -n "$NAMESPACE" >/dev/null 2>&1
}

check_rollout() {
    local resource="$1"
    local name="$2"
    local description="$3"

    if "$KUBECTL" rollout status "$resource/$name" \
        -n "$NAMESPACE" \
        --timeout="$KAFKA_READY_TIMEOUT" >/dev/null 2>&1; then
        pass "$description is ready"
        return 0
    fi

    fail "$description is not ready"
    return 1
}

check_service() {
    local name="$1"
    local expected_selector="$2"
    local expected_port="$3"
    local service_mode="$4"

    local selector
    local service_type
    local cluster_ip
    local ports
    local endpoints

    info "Checking Service: $name"

    if ! resource_exists service "$name"; then
        fail "Service is missing: $name"
        return 1
    fi

    pass "Service exists: $name"

    service_type="$("$KUBECTL" get service "$name" \
        -n "$NAMESPACE" \
        -o jsonpath='{.spec.type}' 2>/dev/null)" || {
        fail "Could not inspect Service type: $name"
        return 1
    }

    if [[ "$service_type" != "ClusterIP" ]]; then
        fail "Service $name is not type ClusterIP"
        return 1
    fi

    cluster_ip="$("$KUBECTL" get service "$name" \
        -n "$NAMESPACE" \
        -o jsonpath='{.spec.clusterIP}' 2>/dev/null)" || {
        fail "Could not inspect Service clusterIP: $name"
        return 1
    }

    if [[ "$service_mode" == "headless" ]]; then
        if [[ "$cluster_ip" != "None" ]]; then
            fail "Service $name is not headless"
            return 1
        fi

        pass "Service $name is correctly configured as headless"
    else
        if [[ -z "$cluster_ip" || "$cluster_ip" == "None" ]]; then
            fail "Service $name has an invalid ClusterIP"
            return 1
        fi

        pass "Service $name has ClusterIP $cluster_ip"
    fi

    selector="$("$KUBECTL" get service "$name" \
        -n "$NAMESPACE" \
        -o jsonpath='{.spec.selector.app}' 2>/dev/null)" || {
        fail "Could not inspect Service selector: $name"
        return 1
    }

    if [[ "$selector" != "$expected_selector" ]]; then
        fail "Service $name has an incorrect selector"
        return 1
    fi

    pass "Service $name has the expected selector"

    ports="$("$KUBECTL" get service "$name" \
        -n "$NAMESPACE" \
        -o jsonpath='{range .spec.ports[*]}{.port}{" "}{end}' \
        2>/dev/null)" || {
        fail "Could not inspect Service ports: $name"
        return 1
    }

    case " $ports " in
        *" $expected_port "*)
            pass "Service $name exposes port $expected_port"
            ;;
        *)
            fail "Service $name is missing port $expected_port"
            return 1
            ;;
    esac

    endpoints="$("$KUBECTL" get endpointslices \
        -n "$NAMESPACE" \
        -l "kubernetes.io/service-name=$name" \
        -o jsonpath='{range .items[*].endpoints[?(@.conditions.ready==true)].addresses[*]}{.}{" "}{end}' \
        2>/dev/null)" || {
        fail "Could not inspect EndpointSlices for Service: $name"
        return 1
    }

    if [[ -z "$endpoints" ]]; then
        fail "Service $name has no ready endpoints"
        return 1
    fi

    pass "Service $name has ready endpoint(s): $endpoints"
    return 0
}

# ------------------------------------------------------------------------------
# Configuration parsing
# ------------------------------------------------------------------------------

load_clusters() {
    local line
    local cluster_id
    local load_balancer_ip
    local kafka_partitions
    local extra
    local line_number=0

    CLUSTER_IDS=()

    if [[ ! -f "$CONFIG_FILE" ]]; then
        fail "Cluster configuration file not found: $CONFIG_FILE"
        return 1
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        line_number=$((line_number + 1))

        # Ignore blank lines and comments.
        [[ -z "${line//[[:space:]]/}" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        IFS='|' read -r cluster_id load_balancer_ip kafka_partitions extra <<< "$line"

        cluster_id="${cluster_id//[[:space:]]/}"
        load_balancer_ip="${load_balancer_ip//[[:space:]]/}"
        kafka_partitions="${kafka_partitions//[[:space:]]/}"

        if [[ -z "$cluster_id" || -z "$load_balancer_ip" || -z "$kafka_partitions" || -n "${extra:-}" ]]; then
            fail "Invalid entry in clusters.conf at line $line_number"
            return 1
        fi

        if [[ ! "$cluster_id" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
            fail "Invalid cluster ID in clusters.conf at line $line_number: $cluster_id"
            return 1
        fi

        CLUSTER_IDS+=("$cluster_id")
    done < "$CONFIG_FILE"

    if [[ ${#CLUSTER_IDS[@]} -eq 0 ]]; then
        fail "No cluster entries found in $CONFIG_FILE"
        return 1
    fi

    pass "Loaded ${#CLUSTER_IDS[@]} cluster(s) from clusters.conf"
    return 0
}

# ------------------------------------------------------------------------------
# Namespace
# ------------------------------------------------------------------------------

check_namespace() {
    if "$KUBECTL" get namespace "$NAMESPACE" >/dev/null 2>&1; then
        pass "Namespace $NAMESPACE exists"
        return 0
    fi

    fail "Namespace $NAMESPACE does not exist"
    return 1
}

# ------------------------------------------------------------------------------
# Kafka
# ------------------------------------------------------------------------------

check_kafka() {
    local topics
    local topic
    local missing=0
    local failed=0
    local kafka_ready=0
    local expected_topics=("$DLQ_TOPIC")

    info "Checking Kafka"

    if check_rollout statefulset "$KAFKA_STATEFULSET" "Kafka StatefulSet"; then
        kafka_ready=1
    else
        failed=1
    fi

    check_service "$KAFKA_SERVICE" "kafka" 9092 cluster || failed=1

    if (( kafka_ready )); then
        if ! topics="$("$KUBECTL" exec -n "$NAMESPACE" \
            "statefulset/$KAFKA_STATEFULSET" -- \
            /opt/kafka/bin/kafka-topics.sh \
            --bootstrap-server "$KAFKA_BROKER" \
            --list 2>/dev/null)"; then
            fail "Kafka broker is not responding to topic-list requests"
            failed=1
        else
            pass "Kafka broker responds to topic-list requests"

            for cluster_id in "${CLUSTER_IDS[@]}"; do
                expected_topics+=("ipfix-$cluster_id")
            done

            for topic in "${expected_topics[@]}"; do
                if grep -Fxq -- "$topic" <<< "$topics"; then
                    pass "Kafka topic exists: $topic"
                else
                    fail "Kafka topic is missing: $topic"
                    missing=1
                fi
            done
        fi
    else
        warn "Skipping Kafka broker/topic checks because the Kafka StatefulSet is not ready"
    fi

    return "$((missing || failed))"
}

# ------------------------------------------------------------------------------
# PostgreSQL
# ------------------------------------------------------------------------------

check_postgres() {
    local query_result
    local failed=0
    local postgres_ready=0

    info "Checking PostgreSQL"

    if check_rollout statefulset "$POSTGRES_STATEFULSET" "PostgreSQL StatefulSet"; then
        postgres_ready=1
    else
        failed=1
    fi

    check_service "$POSTGRES_SERVICE" "ipfix-postgres" 5432 cluster || failed=1
    check_service "$POSTGRES_HEADLESS_SERVICE" "ipfix-postgres" 5432 headless || failed=1

    if (( postgres_ready )); then
        if ! query_result="$("$KUBECTL" exec -n "$NAMESPACE" \
            "statefulset/$POSTGRES_STATEFULSET" -- \
            sh -c 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "SELECT 1"' \
            2>/dev/null)"; then
            fail "PostgreSQL database connection/query failed"
            failed=1
        elif [[ "$query_result" == "1" ]]; then
            pass "PostgreSQL accepts database queries"
        else
            fail "PostgreSQL returned an unexpected query result"
            failed=1
        fi

        if ! query_result="$("$KUBECTL" exec -n "$NAMESPACE" \
            "statefulset/$POSTGRES_STATEFULSET" -- \
            sh -c "psql -v ON_ERROR_STOP=1 -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" -tAc \"SELECT to_regclass('public.$SCHEMA_TABLE')\"" \
            2>/dev/null)"; then
            fail "Could not verify PostgreSQL table: $SCHEMA_TABLE"
            failed=1
        elif [[ "$query_result" == "$SCHEMA_TABLE" ]]; then
            pass "PostgreSQL table exists: $SCHEMA_TABLE"
        else
            fail "PostgreSQL table is missing: $SCHEMA_TABLE"
            failed=1
        fi
    else
        warn "Skipping PostgreSQL database/table checks because the PostgreSQL StatefulSet is not ready"
    fi

    return "$failed"
}

# ------------------------------------------------------------------------------
# GoFlow2
# ------------------------------------------------------------------------------

check_goflow2() {
    local cluster_id
    local deployment
    local service
    local service_type
    local external_address
    local failed=0

    info "Checking GoFlow2 collectors and Services"

    for cluster_id in "${CLUSTER_IDS[@]}"; do
        deployment="goflow-$cluster_id"
        service="goflow-$cluster_id"

        if ! resource_exists deployment "$deployment"; then
            fail "GoFlow2 Deployment is missing: $deployment"
            failed=1
        elif check_rollout deployment "$deployment" "GoFlow2 Deployment $deployment"; then
            :
        else
            failed=1
        fi

        if ! resource_exists service "$service"; then
            fail "GoFlow2 Service is missing: $service"
            failed=1
            continue
        fi

        service_type="$("$KUBECTL" get service "$service" \
            -n "$NAMESPACE" \
            -o jsonpath='{.spec.type}' 2>/dev/null)"

        if [[ "$service_type" != "LoadBalancer" ]]; then
            fail "GoFlow2 Service $service is not type LoadBalancer"
            failed=1
            continue
        fi

        external_address="$("$KUBECTL" get service "$service" \
            -n "$NAMESPACE" \
            -o jsonpath='{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}' \
            2>/dev/null)"

        if [[ -n "$external_address" ]]; then
            pass "GoFlow2 Service $service has external address $external_address"
        else
            fail "GoFlow2 Service $service has no assigned LoadBalancer address"
            failed=1
        fi
    done

    return "$failed"
}

# ------------------------------------------------------------------------------
# Consumer
# ------------------------------------------------------------------------------

check_consumer() {
    info "Checking IPFIX consumer"

    check_rollout deployment "$CONSUMER_DEPLOYMENT" "IPFIX consumer Deployment"
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

echo ""
echo "============================================================"
echo " IPFIX: Deployment Health Check"
echo " Namespace: $NAMESPACE"
echo " Config: $CONFIG_FILE"
echo "============================================================"
echo ""

if ! command -v "$KUBECTL" >/dev/null 2>&1; then
    fail "kubectl command not found: $KUBECTL"
else
    pass "kubectl command found: $KUBECTL"

    if check_namespace; then
        if load_clusters; then
            check_kafka || true
            check_postgres || true
            check_goflow2 || true
            check_consumer || true
        fi
    fi
fi

echo ""
echo "============================================================"
echo " IPFIX: Health Check Summary"
echo "============================================================"
echo " PASS: $PASS_COUNT"
echo " FAIL: $FAIL_COUNT"
echo " WARN: $WARN_COUNT"
echo "============================================================"

if [[ $FAIL_COUNT -gt 0 ]]; then
    echo "[RESULT] IPFIX deployment is NOT healthy."
    exit 1
fi

echo "[RESULT] IPFIX deployment health checks passed."
exit 0