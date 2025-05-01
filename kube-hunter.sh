#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Configuration ---
# Ensure these match the metadata.name in your YAML and your target environment
JOB_NAME="kube-hunter-scan-job"
NAMESPACE="default"
YAML_FILE="kube-hunter-job.yaml"
# Timeout for waiting for the job to complete (e.g., 300s = 5 minutes)
JOB_COMPLETION_TIMEOUT="300s"

# --- Check Prerequisites ---
if ! command -v kubectl &> /dev/null
then
    echo "Error: kubectl command not found. Please ensure kubectl is installed and in your PATH."
    exit 1
fi

if [ ! -f "$YAML_FILE" ]; then
    echo "Error: YAML file '$YAML_FILE' not found in the current directory."
    exit 1
fi

# --- Script Execution ---
echo "Applying Kubernetes Job manifest from '${YAML_FILE}' in namespace '${NAMESPACE}'..."
kubectl apply -f "${YAML_FILE}" -n "${NAMESPACE}"

echo "Waiting up to ${JOB_COMPLETION_TIMEOUT} for Job '${JOB_NAME}' in namespace '${NAMESPACE}' to complete..."
if ! kubectl wait --for=condition=complete "job/${JOB_NAME}" -n "${NAMESPACE}" --timeout="${JOB_COMPLETION_TIMEOUT}"; then
    echo "Error: Job '${JOB_NAME}' did not complete within the timeout period."
    # Optional: Attempt to fetch logs even if timeout occurred or job failed
    echo "Attempting to fetch logs for Job '${JOB_NAME}' despite incomplete status..."
    kubectl logs "job/${JOB_NAME}" -n "${NAMESPACE}" --tail=100 || echo "Could not fetch logs."
    # Optional: Decide if you still want to delete the job on failure/timeout
    # echo "Attempting to delete potentially incomplete Job '${JOB_NAME}'..."
    # kubectl delete job "${JOB_NAME}" -n "${NAMESPACE}" --ignore-not-found=true
    exit 1 # Exit indicating failure
fi

echo "Job '${JOB_NAME}' completed successfully. Fetching logs..."
kubectl logs "job/${JOB_NAME}" -n "${NAMESPACE}"

echo "Log fetching complete."
echo "Deleting Job '${JOB_NAME}' in namespace '${NAMESPACE}'..."
kubectl delete job "${JOB_NAME}" -n "${NAMESPACE}"

echo "Job '${JOB_NAME}' deleted successfully."
echo "Kube-hunter scan process finished."

exit 0
