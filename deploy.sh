#!/usr/bin/env bash
# =============================================================================
# deploy.sh - Manual / CI deployment script for the devops-assessment-app
#
# Usage:
#   ./deploy.sh <environment> <version> <image_registry>
#
# Example:
#   ./deploy.sh production v1.2.3 docker.io/your-dockerhub-username
#
# Behavior:
#   - Validates all inputs
#   - Lints the Helm chart before deploying
#   - Deploys with `helm upgrade --install` (idempotent)
#   - Retries transient command failures with exponential backoff
#   - Waits on `kubectl rollout status` to confirm success
#   - Automatically rolls back with `kubectl rollout undo` / `helm rollback` on failure
#   - Logs everything (stdout+stderr) to deploy.log with timestamps
#   - Uses `trap` for guaranteed cleanup on exit/error/interrupt
#   - Returns proper, distinct exit codes for each failure class
# =============================================================================

set -o errexit
set -o nounset
set -o pipefail

# -----------------------------------------------------------------------
# Constants / exit codes
# -----------------------------------------------------------------------
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_FILE="${SCRIPT_DIR}/deploy.log"
readonly HELM_CHART_PATH="${SCRIPT_DIR}/helm"
readonly NAMESPACE_PREFIX="app"
readonly MAX_RETRIES=3
readonly RETRY_DELAY_SECONDS=5
readonly ROLLOUT_TIMEOUT="120s"

readonly EXIT_SUCCESS=0
readonly EXIT_INVALID_ARGS=10
readonly EXIT_MISSING_DEPENDENCY=11
readonly EXIT_HELM_LINT_FAILED=12
readonly EXIT_DEPLOY_FAILED=13
readonly EXIT_ROLLOUT_FAILED=14
readonly EXIT_SMOKE_TEST_FAILED=15
readonly EXIT_ROLLBACK_FAILED=16

# Populated once inputs are validated
ENVIRONMENT=""
VERSION=""
IMAGE_REGISTRY=""
NAMESPACE=""
RELEASE_NAME=""
DEPLOY_START_EPOCH=""
ROLLBACK_TRIGGERED=0

# -----------------------------------------------------------------------
# Logging helpers - every line is timestamped and written to deploy.log
# and echoed to the console simultaneously.
# -----------------------------------------------------------------------
log() {
    local level="$1"; shift
    local message="$*"
    local timestamp
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "[${timestamp}] [${level}] ${message}" | tee -a "${LOG_FILE}"
}

log_info()  { log "INFO"  "$@"; }
log_warn()  { log "WARN"  "$@"; }
log_error() { log "ERROR" "$@"; }

# -----------------------------------------------------------------------
# Cleanup / trap handling
# Fires on EXIT, ERR, INT, and TERM to guarantee we never leave the
# environment in a silently broken state.
# -----------------------------------------------------------------------
cleanup() {
    local exit_code=$?

    if [[ ${exit_code} -ne 0 && ${ROLLBACK_TRIGGERED} -eq 0 ]]; then
        log_error "Script exiting with code ${exit_code}. Attempting automatic rollback as a safety net."
        rollback || log_error "Safety-net rollback also failed. Manual intervention required."
    fi

    if [[ -n "${DEPLOY_START_EPOCH}" ]]; then
        local end_epoch
        end_epoch="$(date +%s)"
        local duration=$(( end_epoch - DEPLOY_START_EPOCH ))
        log_info "Total deployment script runtime: ${duration}s"
    fi

    log_info "=== deploy.sh finished with exit code ${exit_code} ==="
    exit "${exit_code}"
}
trap cleanup EXIT
trap 'log_error "Interrupted by signal"; exit 130' INT TERM

# -----------------------------------------------------------------------
# Retry wrapper: retries a command up to MAX_RETRIES times with a
# growing delay between attempts. Usage: retry <command...>
# -----------------------------------------------------------------------
retry() {
    local attempt=1
    local cmd=("$@")

    until "${cmd[@]}"; do
        if (( attempt >= MAX_RETRIES )); then
            log_error "Command failed after ${MAX_RETRIES} attempts: ${cmd[*]}"
            return 1
        fi
        local delay=$(( RETRY_DELAY_SECONDS * attempt ))
        log_warn "Attempt ${attempt}/${MAX_RETRIES} failed for: ${cmd[*]}. Retrying in ${delay}s..."
        sleep "${delay}"
        ((attempt++))
    done
    return 0
}

# -----------------------------------------------------------------------
# Input validation
# -----------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} <environment> <version> <image_registry>

  environment      One of: dev, staging, production
  version           Semantic version tag, e.g. v1.2.3
  image_registry    Docker image registry/namespace, e.g. docker.io/myuser

Example:
  ${SCRIPT_NAME} production v1.2.3 docker.io/myuser
EOF
}

validate_inputs() {
    if [[ $# -ne 3 ]]; then
        log_error "Expected 3 arguments, got $#."
        usage
        exit "${EXIT_INVALID_ARGS}"
    fi

    ENVIRONMENT="$1"
    VERSION="$2"
    IMAGE_REGISTRY="$3"

    if [[ ! "${ENVIRONMENT}" =~ ^(dev|staging|production)$ ]]; then
        log_error "Invalid environment '${ENVIRONMENT}'. Must be one of: dev, staging, production."
        exit "${EXIT_INVALID_ARGS}"
    fi

    if [[ ! "${VERSION}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$ ]]; then
        log_error "Invalid version '${VERSION}'. Must follow SemVer, e.g. v1.2.3 or v1.2.3-rc.1."
        exit "${EXIT_INVALID_ARGS}"
    fi

    if [[ -z "${IMAGE_REGISTRY}" || "${IMAGE_REGISTRY}" =~ [[:space:]] ]]; then
        log_error "Invalid image_registry '${IMAGE_REGISTRY}'. Must be a non-empty string with no whitespace."
        exit "${EXIT_INVALID_ARGS}"
    fi

    NAMESPACE="${NAMESPACE_PREFIX}-${ENVIRONMENT}"
    RELEASE_NAME="devops-assessment-app-${ENVIRONMENT}"

    log_info "Validated inputs -> environment=${ENVIRONMENT}, version=${VERSION}, image_registry=${IMAGE_REGISTRY}"
    log_info "Derived -> namespace=${NAMESPACE}, release=${RELEASE_NAME}"
}

check_dependencies() {
    local missing=0
    for bin in kubectl helm; do
        if ! command -v "${bin}" >/dev/null 2>&1; then
            log_error "Required dependency '${bin}' is not installed or not on PATH."
            missing=1
        fi
    done

    if [[ ${missing} -eq 1 ]]; then
        exit "${EXIT_MISSING_DEPENDENCY}"
    fi

    log_info "All required dependencies (kubectl, helm) are present."
    log_info "kubectl version: $(kubectl version --client --short 2>/dev/null || kubectl version --client 2>/dev/null | head -n1)"
    log_info "helm version: $(helm version --short 2>/dev/null || helm version | head -n1)"
}

ensure_namespace() {
    log_info "Ensuring namespace '${NAMESPACE}' exists (idempotent)."
    kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1 || \
        retry kubectl create namespace "${NAMESPACE}"
}

lint_chart() {
    log_info "Linting Helm chart at ${HELM_CHART_PATH}."
    if ! helm lint "${HELM_CHART_PATH}"; then
        log_error "Helm lint failed. Aborting deployment before touching the cluster."
        exit "${EXIT_HELM_LINT_FAILED}"
    fi
    log_info "Helm lint passed."
}

deploy() {
    log_info "Starting helm upgrade --install for release '${RELEASE_NAME}' in namespace '${NAMESPACE}'."
    local image_repo="${IMAGE_REGISTRY}/devops-assessment-app"

    if ! retry helm upgrade --install "${RELEASE_NAME}" "${HELM_CHART_PATH}" \
        --namespace "${NAMESPACE}" \
        --create-namespace \
        --set image.repository="${image_repo}" \
        --set image.tag="${VERSION}" \
        --set env[1].name=APP_VERSION \
        --set env[1].value="${VERSION}" \
        --wait \
        --timeout "${ROLLOUT_TIMEOUT}" \
        --atomic=false; then
        log_error "helm upgrade --install failed after retries."
        exit "${EXIT_DEPLOY_FAILED}"
    fi

    log_info "Helm release applied successfully."
}

wait_for_rollout() {
    log_info "Waiting for rollout status of deployment/${RELEASE_NAME} (timeout ${ROLLOUT_TIMEOUT})."
    if ! kubectl rollout status "deployment/${RELEASE_NAME}" \
        --namespace "${NAMESPACE}" \
        --timeout "${ROLLOUT_TIMEOUT}"; then
        log_error "Rollout did not become healthy within ${ROLLOUT_TIMEOUT}."
        exit "${EXIT_ROLLOUT_FAILED}"
    fi
    log_info "Rollout completed successfully."
}

smoke_test() {
    log_info "Running smoke tests against the deployed service."

    local svc_port
    svc_port="$(kubectl get svc "${RELEASE_NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "80")"

    # Port-forward in the background so we can hit the /health endpoint locally.
    kubectl port-forward "svc/${RELEASE_NAME}" 18080:"${svc_port}" -n "${NAMESPACE}" >/dev/null 2>&1 &
    local pf_pid=$!
    sleep 5

    local http_code
    http_code="$(curl -s -o /dev/null -w '%{http_code}' http://localhost:18080/health || echo "000")"

    kill "${pf_pid}" >/dev/null 2>&1 || true
    wait "${pf_pid}" 2>/dev/null || true

    if [[ "${http_code}" != "200" ]]; then
        log_error "Smoke test failed: /health returned HTTP ${http_code} (expected 200)."
        return 1
    fi

    log_info "Smoke test passed: /health returned HTTP 200."
    return 0
}

rollback() {
    ROLLBACK_TRIGGERED=1
    log_warn "Initiating automatic rollback for release '${RELEASE_NAME}' in namespace '${NAMESPACE}'."

    if helm history "${RELEASE_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
        if retry helm rollback "${RELEASE_NAME}" 0 -n "${NAMESPACE}" --wait --timeout "${ROLLOUT_TIMEOUT}"; then
            log_info "Helm rollback succeeded."
            return 0
        fi
    fi

    log_warn "Helm rollback unavailable or failed; falling back to kubectl rollout undo."
    if kubectl rollout undo "deployment/${RELEASE_NAME}" -n "${NAMESPACE}"; then
        kubectl rollout status "deployment/${RELEASE_NAME}" -n "${NAMESPACE}" --timeout "${ROLLOUT_TIMEOUT}"
        log_info "kubectl rollout undo succeeded."
        return 0
    fi

    log_error "All rollback strategies failed. Manual intervention is required immediately."
    return 1
}

# -----------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------
main() {
    DEPLOY_START_EPOCH="$(date +%s)"
    : > /dev/null # no-op to keep set -e happy on empty log rotation below

    log_info "=== deploy.sh started ==="
    validate_inputs "$@"
    check_dependencies
    ensure_namespace
    lint_chart
    deploy
    wait_for_rollout

    if ! smoke_test; then
        rollback || exit "${EXIT_ROLLBACK_FAILED}"
        exit "${EXIT_SMOKE_TEST_FAILED}"
    fi

    log_info "Deployment of ${RELEASE_NAME} version ${VERSION} to ${ENVIRONMENT} completed successfully."
    exit "${EXIT_SUCCESS}"
}

main "$@"
