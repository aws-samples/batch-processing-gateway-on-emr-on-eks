#!/bin/bash

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - #
# F   U   N   C    T    I    O    N    S
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - #

# Function to get the EKS Cluster ARN, API server endpoint and other details for a given cluster name
get_cluster_configs() {
  cluster_name=$1
  # Get EMR Cluster ARN
  eksCluster=$(aws eks describe-cluster --name "$cluster_name" --query "cluster.arn" --output text)
  # Retrieve the master URL for the current cluster context
  masterUrl=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
  # Get the secret name associated with the Spark Operator service account
  saSecret=$(kubectl -n spark-operator get sa/emr-containers-sa-spark-operator -o json | jq -r '.secrets[] | .name')
  # Retrieve the CA certificate data from the secret
  caCertDataSOPS=$(kubectl -n spark-operator get secret/"$saSecret" -o json | jq -r '.data."ca.crt"')
  # Retrieve the token name associated with the Spark Operator service account
  TOKEN_NAME=$(kubectl get -n spark-operator serviceaccount/emr-containers-sa-spark-operator -o jsonpath='{.secrets[0].name}')
  # Decode the user token from the secret
  userTokenSOPS=$(kubectl get -n spark-operator secret "$TOKEN_NAME" -o jsonpath='{.data.token}' | base64 --decode)
}

# Update the values.yaml with Amazon EMR on EKS Cluster values
update_cluster_values() {
    # Loop through the cluster_ids array 
    for i in "${!cluster_ids[@]}"; do
      cluster_name="${cluster_ids[$i]}"
      # Get the kubectl context for the cluster
      context=$(kubectl config get-contexts -o name | grep "$cluster_name")
      # Set the kubectl context
      kubectl config use-context "$context"
      # Verify the right current context 
      kubectl config current-context

      # Get all Amazon EMR on EKS cluster details 
      get_cluster_configs "$cluster_name"

      # Update the YAML file using yq
      yq e "
        (.plainConfig.sparkClusters[] | select(.id == \"$cluster_name\") | .eksCluster) = \"$eksCluster\" |
        (.plainConfig.sparkClusters[] | select(.id == \"$cluster_name\") | .masterUrl) = \"$masterUrl\" |
        (.plainConfig.sparkClusters[] | select(.id == \"$cluster_name\") | .caCertDataSOPS) = \"$caCertDataSOPS\" |
        (.plainConfig.sparkClusters[] | select(.id == \"$cluster_name\") | .userTokenSOPS) = \"$userTokenSOPS\"
      " -i "$outputFile"
   done
}

# Update the values.yaml with Amazon RDS values
update_db_values() {
  # Connection String
  db_endpoint=$(aws rds describe-db-instances --db-instance-identifier "$db_identifier" --query 'DBInstances[0].Endpoint.Address' --output text)
  db_jdbc_url="jdbc:mysql://${db_endpoint}:3306/bpg?useUnicode=yes&characterEncoding=UTF-8&useLegacyDatetimeCode=false&connectTimeout=10000&socketTimeout=30000"
  # Username and Password
  db_secret_arn=$(aws secretsmanager list-secrets | jq -r --arg dbname "$db_identifier" '.SecretList[] | select(.Tags[] | select(.Key == "aws:rds:primaryDBClusterArn" and (.Value | tostring | endswith("\($dbname)")))) | .ARN')
  db_username=$(aws secretsmanager get-secret-value --secret-id "$db_secret_arn" --query SecretString --output text | jq -r .username)
  db_password=$(aws secretsmanager get-secret-value --secret-id "$db_secret_arn" --query SecretString --output text | jq -r .password)

  # Update the YAML file using yq
  yq e "
    (.plainConfig.dbStorageSOPS.connectionString) = \"$db_jdbc_url\" |
    (.plainConfig.dbStorageSOPS.user) = \"$db_username\" |
    (.plainConfig.dbStorageSOPS.password) = \"$db_password\" |
    (.plainConfig.dbStorageSOPS.dbName) = \"$db_identifier\"
  " -i "$outputFile"
}

# Update the values.yaml with Amazon ECR values
update_ecr_values() {
  ecr_repo=$aws_account_id.dkr.ecr.$aws_region.amazonaws.com

  # Update the YAML file using yq
  yq e "
    (.image.registry) = \"$ecr_repo\"
  " -i "$outputFile"
}

# Function to look up ECR registry account for a given region
lookup_ecr_account() {
    # https://docs.aws.amazon.com/emr/latest/EMR-on-EKS-DevelopmentGuide/docker-custom-images-tag.html#docker-custom-images-ECR
    local region="$1"
    case "$region" in
        "ap-northeast-1") echo "059004520145" ;;
        "ap-northeast-2") echo "996579266876" ;;
        "ap-south-1") echo "235914868574" ;;
        "ap-southeast-1") echo "671219180197" ;;
        "ap-southeast-2") echo "038297999601" ;;
        "ca-central-1") echo "351826393999" ;;
        "eu-central-1") echo "107292555468" ;;
        "eu-north-1") echo "830386416364" ;;
        "eu-west-1") echo "483788554619" ;;
        "eu-west-2") echo "118780647275" ;;
        "eu-west-3") echo "307523725174" ;;
        "sa-east-1") echo "052806832358" ;;
        "us-east-1") echo "755674844232" ;;
        "us-east-2") echo "711395599931" ;;
        "us-west-1") echo "608033475327" ;;
        "us-west-2") echo "895885662937" ;;
        *) echo "Unknown region" ;;
    esac
}

# Update the values.yaml with Amazon EMR on EKS Spark Docker Image Url 
update_spark_images() {
  ecr_account=$(lookup_ecr_account "$aws_region")
  spark_images=$ecr_account.dkr.ecr.$aws_region.amazonaws.com/spark/emr-7.1.0:latest

  # Update the YAML file using yq
  yq e "
    (.plainConfig.sparkImages[0].name) = \"$spark_images\"
  " -i "$outputFile"
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - #
# M   A   I   N
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - #
echo "Script started ..."

# ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ #
# Variables - Start
# ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ #

# Database Name 
db_identifier="bpg"
# Amazon EMR on EKS cluster array
cluster_ids=("spark-cluster-a" "spark-cluster-b")
# The input YAML file template
inputFile="values.template.yaml"
# The output YAML file 
outputFile="values.yaml"

# AWS Region 
aws_region=$AWS_REGION
# Check for errors
if [ -z "$aws_region" ]; then
  echo "AWS_REGION is not set. Set the AWS_REGION value in the shell. Exiting."
  exit 0
fi

# AWS Account Id
aws_account_id=$(aws sts get-caller-identity --query "Account" --output text)

# ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ #
# Variables - End 
# ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ #

# Copy the template file to output file 
cp "$inputFile" "$outputFile"

# Amazon EMR on EKS updates
update_cluster_values

# Amazon RDS updates
update_db_values

# Amazon ECR updates
update_ecr_values

# Amazon EMR on EKS Spark Image update
update_spark_images

echo "The YAML file has been updated and saved as $outputFile"
echo "Script completed"

