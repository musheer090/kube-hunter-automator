## Kube-Hunter Scan Automation Script

### 1. Overview

This shell script provides a robust and automated solution for executing `kube-hunter` scans on Kubernetes clusters. It manages the entire end-to-end lifecycle of the security scan, including the deployment of the scanning job, monitoring for completion, retrieval of logs, and secure archival of the final report to an AWS S3 bucket.

The primary use case for this tool is to facilitate regular, scheduled penetration testing and security auditing, such as part of a Kubernetes CronJob or a traditional cron job on a bastion host, ensuring continuous security monitoring of your cluster environment.

### 2. Features

* **Automated Execution**: Deploys the `kube-hunter` Kubernetes job with a single command, streamlining the scan initiation process.
* **Synchronous Monitoring**: The script actively waits for the Kubernetes job to reach a `Completed` state before proceeding to the next steps, ensuring logs are captured only upon successful execution.
* **Prerequisite Checks & Error Handling**: Includes validation for required command-line tools (`kubectl`, `aws`) and incorporates graceful error handling for job failures or timeouts.
* **Secure Cloud Archival**: Automatically uploads the generated scan report to a specified AWS S3 bucket for centralized storage, analysis, and review.
* **Structured Reporting**: Organizes scan reports within the S3 bucket using a `YYYY-MM-DD/HHMMSS/` directory structure for clear, chronological versioning.
* **Automatic Resource Cleanup**: Deletes the Kubernetes job resource post-scan to maintain cluster hygiene and avoid resource clutter.
* **Highly Configurable**: Script behavior can be customized via shell variables or overridden by environment variables for flexible integration into different workflows.

### 3. Prerequisites

Ensure the following dependencies are installed and configured on the execution environment:

* **`kubectl`**: Authenticated and authorized to interact with the target Kubernetes cluster.
* **AWS CLI (v2 recommended)**: Configured with valid AWS credentials. The IAM principal executing the script requires programmatic AWS access.
* **`kube-hunter-job.yaml`**: A valid Kubernetes Job manifest for `kube-hunter` must be present in the same directory as the script. An example manifest is provided in the repository.

### 4. Configuration

The script's parameters can be modified by editing the variables within the script or by setting environment variables, which will take precedence.

| Variable | Environment Variable | Default Value | Description |
| :--- | :--- | :--- | :--- |
| `YAML_FILE` | `YAML_FILE` | `kube-hunter-job.yaml` | The filename of the Kubernetes Job manifest. |
| `JOB_NAME` | `JOB_NAME` | `kube-hunter-scan-job` | The `metadata.name` of the Job defined in the YAML file. |
| `S3_BUCKET` | `S3_BUCKET` | `kubeguard-reports` | The target AWS S3 bucket for report uploads. |
| `AWS_REGION` | `AWS_REGION` | `ap-south-1` | The AWS region of the target S3 bucket. |

**To override a default setting via an environment variable:**
```bash
export S3_BUCKET="my-production-reports-bucket"
./kube-hunter.sh
```

### 5. Usage

#### 5.1. Quick Start

This command clones the repository, sets permissions, executes the scan, and cleans up the local directory.
```bash
git clone https://github.com/musheer090/kube-hunter-automator.git && \
cd kube-hunter-automator && \
chmod +x kube-hunter.sh && \
./kube-hunter.sh && \
cd .. && \
rm -rf kube-hunter-automator
```

#### 5.2. Manual Execution

1.  **Clone the repository:**
    ```bash
    git clone https://github.com/musheer090/kube-hunter-automator.git
    cd kube-hunter-automator
    ```
2.  **Set execute permissions for the script:**
    ```bash
    chmod +x kube-hunter.sh
    ```
3.  **Run the script:**
    ```bash
    ./kube-hunter.sh
    ```

### 6. Required IAM Permissions

The AWS IAM principal (User or Role) executing the script requires the following minimum permissions.

* `sts:GetCallerIdentity`: To verify the active AWS identity.
* `s3:HeadBucket`: To validate the existence of the target S3 bucket.
* `s3:PutObject`: To upload the report to the specified S3 path.

Below is a sample IAM policy. **Note: Replace `kubeguard-reports` with the name of your S3 bucket.**

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "AllowKubeHunterScriptActions",
            "Effect": "Allow",
            "Action": "sts:GetCallerIdentity",
            "Resource": "*"
        },
        {
            "Sid": "AllowS3BucketInteractions",
            "Effect": "Allow",
            "Action": "s3:HeadBucket",
            "Resource": "arn:aws:s3:::kubeguard-reports"
        },
        {
            "Sid": "AllowReportUpload",
            "Effect": "Allow",
            "Action": "s3:PutObject",
            "Resource": "arn:aws:s3:::kubeguard-reports/kube-hunter-reports/*"
        }
    ]
}
```

### 7. Scheduled Execution with Cron

To automate scans on a recurring schedule, configure a cron job.

1.  **Open the crontab editor:**
    ```bash
    crontab -e
    ```
2.  **Add an entry to schedule the script.** The following example executes the scan daily at 02:00. For reliable execution, always use absolute paths for the script and any log redirection.

    ```bash
    # Run Kube-Hunter scan every day at 2:00 AM
    0 2 * * * /path/to/kube-hunter-automator/kube-hunter.sh >> /var/log/kube-hunter-cron.log 2>&1
    ```
