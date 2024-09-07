#!/bin/bash
set -euo pipefail

# This script automates the setup of an Amazon EKS cluster with EMR and Spark Operator.
# It includes functions for configuring AWS environment variables, creating an EKS cluster,
# setting up necessary IAM roles and policies, and installing the Spark Operator using Helm.
# The script performs the following tasks:
# 1. Sets AWS region, account ID, and cluster name.
# 2. Verifies the presence and permissions of the keypair file.
# 3. Retrieves public subnets of the default VPC.
# 4. Creates an EKS cluster and configures namespace and IAM mappings for EMR on EKS.
# 5. Applies Kubernetes role and role binding for the cluster.
# 6. Sets up EMR on EKS, including creating a virtual cluster and associating IAM OIDC provider.
# 7. Logs in to ECR, installs the Spark Operator Helm chart, and configures necessary secrets.
# Ensure you have the necessary AWS CLI and kubectl configurations before running the script.
# Make sure to replace placeholder values (e.g., role names, file paths) with actual values as needed.


# Set Region
set_region() {
  export AWS_REGION=$1
}

# Set Account Id
get_account_id() {
  export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
}

# Set Cluster Name 
set_cluster_name() {
  export CLUSTER_NAME=$1
}

# Check the presence of KeyPair file and it's permission
check_keypair_presence_and_permission() {
  local FILE_PATH=$1 

  if [[ -f "$FILE_PATH" ]]; then
    echo "File '$FILE_PATH' exists."
    
    # Check if file has permission 400
    local FILE_PERMISSION 
    FILE_PERMISSION=$(ls -l "$FILE_PATH" | awk '{print $1}')
    
    if [[ "$FILE_PERMISSION" == "-r--------" ]]; then
      echo "File '$FILE_PATH' has the correct permissions: 400."
      export KEYPAIR="$FILE_PATH"
    else
      echo "File '$FILE_PATH' does not have the correct permissions. Current permissions are: $FILE_PERMISSION. Existing with error."
      exit 1
    fi
  else
    echo "File '$FILE_PATH' does not exist. Exiting with error."
    exit 1
  fi
}

# Get Public Subnets of Default VPC

# Filter out us-east-1e subnet due to its known limitation in supporting the Amazon EKS control plane.
# This Availability Zone (AZ) in the us-east-1 region does not reliably support EKS cluster control planes,
# and attempting to use it can result in errors or failed deployments. To ensure smooth cluster creation,
# we exclude it from the list of default subnets when passing subnets to the eksctl create cluster command.
# Error Message: "Cannot create cluster "<spark cluster name>" because EKS does not support
# creating control plane instances in us-east-le, the targeted availability zone. Retry cluster creation 
# using control plane subnets that span at least two of these availability zone

get_default_vpc_subnets() {
  export  DEFAULT_FOR_AZ_SUBNET=$(aws ec2 describe-subnets --region "$AWS_REGION" --filters "Name=default-for-az,Values=true" --query "Subnets[?AvailabilityZone != 'us-east-1e'].SubnetId" | jq -r '. | map(tostring) | join(",")')
}

# Create Amazon EKS Cluster
create_eks_cluster() {
  # Check if the cluster already exists
  echo "Checking if cluster $CLUSTER_NAME exists in region $AWS_REGION..."
  if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" > /dev/null 2>&1; then
    echo "Cluster $CLUSTER_NAME already exists in region $AWS_REGION."
    return 0
  else
    echo "Cluster $CLUSTER_NAME does not exist. Proceeding with creation..."
  fi

  # Create Amazon EKS Cluster
  eksctl create cluster \
    --name "$CLUSTER_NAME" \
    --region "$AWS_REGION" \
    --vpc-public-subnets "$DEFAULT_FOR_AZ_SUBNET" \
    --with-oidc \
    --ssh-access \
    --ssh-public-key "$KEYPAIR" \
    --instance-types=m5.xlarge \
    --managed
}

# Create Namespace for Spark Jobs
# With a manifest, kubectl apply is idempotent
create_namespace() {
  kubectl apply -f namespace.yaml
}

# Enable Cluster Access for Amazon EMR on EKS
enable_cluster_access() {
  eksctl create iamidentitymapping \
    --cluster "$CLUSTER_NAME" \
    --namespace spark-jobs \
    --region "$AWS_REGION" \
    --service-name "emr-containers"
}

# Apply Kubernetes Role and Role Binding
apply_k8s_role_and_binding() {
  kubectl apply -f role.yaml
  kubectl apply -f role-binding.yaml
}

# Identify the ARN for the AWSServiceRoleForAmazonEMRContainers Role
get_service_role_arn() {
  export ARN=$(aws iam get-role --role-name AWSServiceRoleForAmazonEMRContainers --region "$AWS_REGION" --query 'Role.Arn' --output text)
}

# Update AWS Auth Config Map
update_aws_auth_config_map() {
  eksctl create iamidentitymapping \
    --cluster "$CLUSTER_NAME" \
    --arn "$ARN" \
    --region "$AWS_REGION" \
    --username emr-containers
}

# Get OIDC Provider
get_oidc_provider() {
  aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query "cluster.identity.oidc.issuer" --output text
}

# Associate IAM OIDC Provider
associate_iam_oidc_provider() {
  eksctl utils associate-iam-oidc-provider --cluster "$CLUSTER_NAME" --region "$AWS_REGION" --approve
}

# Create IAM Role
create_iam_role() {
  local ROLE_NAME="sparkjobrole" 
  
  # Check if the role exists
  if aws iam get-role --role-name "$ROLE_NAME" > /dev/null 2>&1; then
    echo "Role '$ROLE_NAME' already exists."
  else
    echo "Creating role '$ROLE_NAME'..."
    aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document file://eks-trust-policy.json
  fi
}

# Attach Policy to Role
attach_policy_to_role() {
  local ROLE_NAME="sparkjobrole"
  local POLICY_NAME="EMR-Spark-Job-Execution" 

  # Check if the policy exists in the role
  if aws iam list-role-policies --role-name "$ROLE_NAME" | grep -q "$POLICY_NAME"; then
    echo "Policy '$POLICY_NAME' already attached to role '$ROLE_NAME'."
  else
    echo "Attaching policy '$POLICY_NAME' to role '$ROLE_NAME'..."
    aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name "$POLICY_NAME" --policy-document file://eks-job-role-policy.json
  fi
}

# Update Role Trust Policy
update_role_trust_policy() {
  aws emr-containers update-role-trust-policy --region "$AWS_REGION" --cluster-name "$CLUSTER_NAME" --namespace spark-jobs --role-name sparkjobrole
}

# Setup EMR on EKS Cluster
setup_emr_on_eks() {
  # Check if the virtual cluster already exists (CREATING or RUNNING state)
  echo "Checking if virtual cluster ${CLUSTER_NAME}-v exists in region ${AWS_REGION}..."
  EXISTING_CLUSTER=$(aws emr-containers list-virtual-clusters --region "$AWS_REGION" --query "virtualClusters[?name=='${CLUSTER_NAME}-v' && (state=='CREATING' || state=='RUNNING')] | [0].id" --output text)

  if [ "$EXISTING_CLUSTER" != "None" ]; then
    echo "Virtual cluster ${CLUSTER_NAME}-v already exists with ID ${EXISTING_CLUSTER}."
    return 0
  else
    echo "Virtual cluster ${CLUSTER_NAME}-v does not exist. Proceeding with creation..."
  fi

  JSON_TEMPLATE='{
    "id": "%s",
    "type": "EKS",
    "info": {
        "eksInfo": {
            "namespace": "spark-jobs"
        }
    }
  }'

  JSON_DATA=$(printf "${JSON_TEMPLATE}" "${CLUSTER_NAME}")
  aws emr-containers create-virtual-cluster \
    --name "${CLUSTER_NAME}-v" \
    --region "$AWS_REGION" \
    --container-provider "$JSON_DATA"
}

# Login to ECR
login_to_ecr() {
  aws ecr get-login-password \
    --region "$AWS_REGION" | helm registry login \
    --username AWS \
    --password-stdin "$1".dkr.ecr."$AWS_REGION".amazonaws.com
}

# Install Helm Chart
install_helm_chart() {
  local RELEASE_NAME="spark-operator-demo"
  local NAMESPACE="spark-operator"
  local CHART_URL="oci://$1.dkr.ecr."$AWS_REGION".amazonaws.com/spark-operator"
  local CHART_VERSION="7.1.0"

  if helm ls -n "$NAMESPACE" | grep -q "$RELEASE_NAME"; then
    echo "Helm release $RELEASE_NAME already exists in namespace $NAMESPACE. Upgrading..."
    helm upgrade "$RELEASE_NAME" "$CHART_URL" \
      --set emrContainers.awsRegion="$AWS_REGION" \
      --version "$CHART_VERSION" \
      --namespace "$NAMESPACE"
  else
    echo "Installing Helm release $RELEASE_NAME in namespace $NAMESPACE..."
    helm install "$RELEASE_NAME" "$CHART_URL" \
      --set emrContainers.awsRegion="$AWS_REGION" \
      --version "$CHART_VERSION" \
      --namespace "$NAMESPACE" \
      --create-namespace
  fi
}

# Create Secret for Service Account
create_secret() {
  kubectl apply -f secret.yaml
}

# Attach Secret to Service Account
attach_secret_to_service_account() {
  kubectl patch serviceaccount emr-containers-sa-spark-operator -n spark-operator -p '{"secrets": [{"name": "emr-containers-sa-spark-operator-token"}]}'
}

# Main
main() {

  if [ $# -eq 0 ]; then
    echo "No cluster names provided. Exiting."
    exit 1
  fi

  # No AWS CLI Output
  export AWS_PAGER=""

  # Set environment
  set_region "${AWS_REGION:?}"
  get_account_id
  check_keypair_presence_and_permission "${KEY_RELATIVE_PATH:?}"
  get_default_vpc_subnets
  
  # Loop through cluster names and create clusters
  for cluster_name in "${@}"; do
    set_cluster_name "${cluster_name}"
    
    echo "Processing cluster: $CLUSTER_NAME"
    
    # Create EKS cluster
    create_eks_cluster
    create_namespace
    enable_cluster_access
    
    # Apply k8s changes
    apply_k8s_role_and_binding
    get_service_role_arn
    update_aws_auth_config_map
    get_oidc_provider
    associate_iam_oidc_provider
    create_iam_role
    attach_policy_to_role
    update_role_trust_policy
    
    # Setup EMR on EKS 
    setup_emr_on_eks
    login_to_ecr "$(bash ../lookup_ecr_account.sh)"
    install_helm_chart "$(bash ../lookup_ecr_account.sh)"
    create_secret
    attach_secret_to_service_account

    echo "Cluster setup completed for: $CLUSTER_NAME"
  done
}

# Start the main function with all the provided arguments
main "$@"
