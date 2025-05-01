#!/bin/bash

# Kube-Hunter Automator with S3 Upload
# - Applies a kube-hunter job manifest.
# - Waits for the job to complete.
# - Fetches the job logs (the report).
# - Uploads the logs to a specified AWS S3 bucket.
# - Deletes the job afterwards.
# - Includes basic error handling and AWS checks.

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Configuration ---
# Kubernetes Job Settings (Ensure these match your YAML)
JOB_NAME="kube-hunter-scan-job"
NAMESPACE="default"
YAML_FILE="kube-hunter-job.yaml"
JOB_COMPLETION_TIMEOUT="300s" # e.g., 300s = 5 minutes

# AWS S3 Upload Settings (MODIFY THESE or set Environment Variables)
# You can override these by setting environment variables with the same names
# Example: export S3_BUCKET="my-secure-bucket"
DEFAULT_S3_BUCKET_NAME="kubeguard-reports" # <<< Bucket name set as requested!
DEFAULT_AWS_REGION="ap-south-1"            # <<< CHANGE THIS if needed (e.g., us-east-1)
S3_BASE_FOLDER="kube-hunter-reports"       # Top-level folder within the bucket

# Use environment variables if set, otherwise use defaults
S3_BUCKET_NAME="${S3_BUCKET:-$DEFAULT_S3_BUCKET_NAME}"
AWS_REGION="${AWS_REGION:-$DEFAULT_AWS_REGION}"

# --- Helper Functions ---
check_tool() {
    TOOL_NAME=$1
    echo -n "Checking for ${TOOL_NAME}... "
    if ! command -v ${TOOL_NAME} >/dev/null 2>&1; then
        echo "[MISSING]"
        # Provide specific error messages
        if [[ "$TOOL_NAME" == "kubectl" ]]; then
            echo "  Error: kubectl command not found. Please install and configure kubectl."
            return 1
        elif [[ "$TOOL_NAME" == "aws" ]]; then
            echo "  Error: aws command not found. Please install AWS CLI v2 and configure it."
            return 1
        else
             echo "  Error: Prerequisite ${TOOL_NAME} not found."
             return 1
        fi
    else
        echo "[OK]"
        return 0
    fi
}

# --- 1. Prerequisite Checks ---
echo "--- Checking Prerequisites ---"
check_tool "kubectl" || exit 1
check_tool "aws"     || exit 1 # Added AWS CLI check

if [ ! -f "$YAML_FILE" ]; then
    echo "Error: YAML file '$YAML_FILE' not found in the current directory."
    exit 1
fi
echo "-----------------------------"
echo

# --- 2. AWS Identity & S3 Bucket Check ---
echo "--- AWS & S3 Checks ---"
echo "Checking AWS identity..."
AWS_IDENTITY=$(aws sts get-caller-identity --output text --query 'Arn' --region "${AWS_REGION}" 2>/dev/null)
if [ $? -ne 0 ]; then
    echo "[ERROR] Failed to get AWS caller identity. Is AWS CLI configured correctly for region ${AWS_REGION}?"
    exit 1
fi
echo "Script will use AWS identity: ${AWS_IDENTITY}"
echo "Ensure this identity has 's3:PutObject' permissions on 's3://${S3_BUCKET_NAME}/${S3_BASE_FOLDER}/*'"
echo "Ensure this identity has 's3:HeadBucket' or 's3:ListBucket' permissions for '${S3_BUCKET_NAME}'."

echo "Checking S3 bucket '${S3_BUCKET_NAME}' in region '${AWS_REGION}'..."
if ! aws s3api head-bucket --bucket "${S3_BUCKET_NAME}" --region "${AWS_REGION}" >/dev/null 2>&1; then
    echo "[ERROR] Bucket '${S3_BUCKET_NAME}' does not exist in region '${AWS_REGION}', or you lack permissions to access it."
    echo "Please create the bucket or check permissions/region."
    exit 1
fi
echo "[OK] S3 bucket '${S3_BUCKET_NAME}' is accessible."
echo "-----------------------"
echo

# --- 3. Execute Kubernetes Job ---
echo "--- Running Kube-Hunter Job ---"
echo "Applying Kubernetes Job manifest from '${YAML_FILE}' in namespace '${NAMESPACE}'..."
kubectl apply -f "${YAML_FILE}" -n "${NAMESPACE}"

echo "Waiting up to ${JOB_COMPLETION_TIMEOUT} for Job '${JOB_NAME}' in namespace '${NAMESPACE}' to complete..."
if ! kubectl wait --for=condition=complete "job/${JOB_NAME}" -n "${NAMESPACE}" --timeout="${JOB_COMPLETION_TIMEOUT}"; then
    echo "[ERROR] Job '${JOB_NAME}' did not complete within the timeout period or failed."
    # Attempt to fetch logs even if timeout occurred or job failed
    echo "Attempting to fetch logs for Job '${JOB_NAME}' despite incomplete status..."
    TEMP_LOG_FILE=$(mktemp /tmp/kube-hunter-log.XXXXXX) # Create a temporary file
    echo "Saving logs to temporary file: ${TEMP_LOG_FILE}"
    # Try to get logs, redirect stderr to stdout to capture potential errors in the log file itself
    kubectl logs "job/${JOB_NAME}" -n "${NAMESPACE}" --tail=500 > "${TEMP_LOG_FILE}" 2>&1 || echo "[WARN] Could not fetch logs for failed/incomplete job."

    # Attempt to upload the failure log
    if [ -s "${TEMP_LOG_FILE}" ]; then # Check if log file is not empty
        CURRENT_DATE=$(date +'%Y-%m-%d')
        CURRENT_TIME=$(date +'%H%M%S')
        S3_PATH="s3://${S3_BUCKET_NAME}/${S3_BASE_FOLDER}/${CURRENT_DATE}/${CURRENT_TIME}/FAILED_${JOB_NAME}_report.log"
        echo "Attempting to upload failure log to ${S3_PATH}..."
        if aws s3 cp "${TEMP_LOG_FILE}" "${S3_PATH}" --region "${AWS_REGION}"; then
            echo "[OK] Failure log uploaded to S3."
        else
            echo "[WARN] Failed to upload failure log to S3."
        fi
    else
        echo "[INFO] No logs captured for failed/incomplete job, skipping S3 upload."
    fi
    rm -f "${TEMP_LOG_FILE}" # Clean up temp file

    # Optional: Decide if you still want to delete the job on failure/timeout
    echo "Attempting to delete potentially incomplete Job '${JOB_NAME}'..."
    kubectl delete job "${JOB_NAME}" -n "${NAMESPACE}" --ignore-not-found=true
    exit 1 # Exit indicating failure
fi
echo "[OK] Job '${JOB_NAME}' completed successfully."
echo "-----------------------------"
echo

# --- 4. Fetch Logs and Upload to S3 ---
echo "--- Fetching Logs & Uploading Report ---"
# Create a temporary file to store the logs
TEMP_LOG_FILE=$(mktemp /tmp/kube-hunter-report.XXXXXX)
echo "Fetching logs and saving to temporary file: ${TEMP_LOG_FILE}"

# Fetch logs from the completed job and save to the temp file
if ! kubectl logs "job/${JOB_NAME}" -n "${NAMESPACE}" > "${TEMP_LOG_FILE}"; then
    echo "[ERROR] Failed to fetch logs from completed job '${JOB_NAME}'."
    rm -f "${TEMP_LOG_FILE}" # Clean up temp file
    # Still try to delete the job
    echo "Attempting to delete Job '${JOB_NAME}'..."
    kubectl delete job "${JOB_NAME}" -n "${NAMESPACE}" --ignore-not-found=true
    exit 1
fi

# Check if the log file was actually created and has content
if [ ! -s "${TEMP_LOG_FILE}" ]; then
    echo "[WARN] Log file fetched successfully but is empty. Skipping S3 upload."
    rm -f "${TEMP_LOG_FILE}" # Clean up temp file
    # Still try to delete the job
    echo "Attempting to delete Job '${JOB_NAME}'..."
    kubectl delete job "${JOB_NAME}" -n "${NAMESPACE}" --ignore-not-found=true
    # Decide if an empty log is an error or just a warning
    # exit 1 # Uncomment if empty log is considered a failure
    echo "[INFO] Proceeding with job deletion despite empty log."
else
    echo "[OK] Logs fetched successfully to ${TEMP_LOG_FILE}."

    # Prepare S3 destination path
    CURRENT_DATE=$(date +'%Y-%m-%d')
    CURRENT_TIME=$(date +'%H%M%S')
    S3_REPORT_FILENAME="${JOB_NAME}_report_${CURRENT_DATE}_${CURRENT_TIME}.log"
    S3_DESTINATION_PATH="s3://${S3_BUCKET_NAME}/${S3_BASE_FOLDER}/${CURRENT_DATE}/${CURRENT_TIME}/${S3_REPORT_FILENAME}"

    echo "Uploading report to: ${S3_DESTINATION_PATH}"

    # Upload the log file using AWS CLI
    if aws s3 cp "${TEMP_LOG_FILE}" "${S3_DESTINATION_PATH}" --region "${AWS_REGION}"; then
        echo "[OK] Report successfully uploaded to S3."
    else
        echo "[ERROR] Failed to upload report to S3. Check AWS permissions or network."
        # Decide if this is a fatal error
        rm -f "${TEMP_LOG_FILE}" # Clean up temp file
        # Still try to delete the job
        echo "Attempting to delete Job '${JOB_NAME}'..."
        kubectl delete job "${JOB_NAME}" -n "${NAMESPACE}" --ignore-not-found=true
        exit 1 # Exit indicating upload failure
    fi

    # Clean up the temporary log file
    rm -f "${TEMP_LOG_FILE}"
    echo "Temporary log file cleaned up."
fi # End of check for non-empty log file

echo "----------------------------------------"
echo

# --- 5. Delete Kubernetes Job ---
echo "--- Cleaning Up ---"
echo "Deleting Job '${JOB_NAME}' in namespace '${NAMESPACE}'..."
if kubectl delete job "${JOB_NAME}" -n "${NAMESPACE}"; then
    echo "[OK] Job '${JOB_NAME}' deleted successfully."
else
    # Adding ignore-not-found check here as well for robustness
    if kubectl get job "${JOB_NAME}" -n "${NAMESPACE}" > /dev/null 2>&1; then
         echo "[WARN] Failed to delete job '${JOB_NAME}', but it might still exist. Manual check recommended."
    else
         echo "[INFO] Job '${JOB_NAME}' already deleted or deletion command failed after it was gone."
    fi
fi
echo "-----------------"
echo

# --- 6. Final Summary ---
echo "--- Kube-Hunter Scan Process Finished ---"
# Check if S3_DESTINATION_PATH was set (i.e., if upload was attempted)
if [ -n "${S3_DESTINATION_PATH}" ]; then
    echo "[SUCCESS] Job ran, logs fetched, and report uploaded."
    echo " Report uploaded to: ${S3_DESTINATION_PATH}"
else
    # This case handles if the log file was empty and upload was skipped
    echo "[SUCCESS] Job ran and completed. Log file was empty, so no report uploaded."
fi
echo "Exiting with status 0 (success)."
exit 0
