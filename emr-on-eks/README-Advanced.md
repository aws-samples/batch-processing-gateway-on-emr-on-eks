# Setting up Amazon EMR on EKS clusters with Spark operator

This ```README``` provides step by step guide to create Amazon EMR on EKS clusters with Spark operator.

#### 1.Change to appropriate directory

```sh
cd ~/batch-processing-gateway-on-emr-on-eks/emr-on-eks/
```

#### 2. Set Region

```sh
export AWS_REGION=<AWS_REGION>
```

#### 3. Create key pair
See the official guidance on how to [Create a Key Pair](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/create-key-pairs.html)
Ensure that you follow your organization’s best practices for Keypair management.

```sh
aws ec2 create-key-pair \
--region "$AWS_REGION" \
--key-name emrkp \
--key-type ed25519 \
--key-format pem \
--query "KeyMaterial" \
--output text > emrkp.pem

chmod 400 emrkp.pem
ssh-keygen -y -f emrkp.pem > emr_publickey.pem
chmod 400 emr_publickey.pem
```

#### 4. Setup Amazon EMR on EKS clusters 
To implement the solution, we will set up two EMR on EKS clusters. 
For each cluster, set the variable ```CLUSTER_NAME``` to ```spark-cluster-a``` and repeat steps 3-5. 
Then, set the variable ```CLUSTER_NAME``` to ```spark-cluster-b``` and repeat steps 3-5 again.

#### 4.1 Set Cluster Name 

```sh
export CLUSTER_NAME=<CLUSTER_NAME>
```

#### 4.2 Get Public Subnets of your default VPC

**Disclaimer**: For the purposes of this post, we utilized the default VPC for deploying the solution. Please modify the steps below to deploy the solution into the appropriate VPC in accordance with your organization’s best practices.See the official guidance on how to [Create a VPC](https://docs.aws.amazon.com/vpc/latest/userguide/create-vpc.html)

```sh
export DEFAULT_FOR_AZ_SUBNET=$(aws ec2 describe-subnets --region $AWS_REGION --filters "Name=default-for-az,Values=true" --query "Subnets[*].SubnetId" | jq -r '. | map(tostring) | join(",")')
```

#### 4.3 Create Amazon EKS cluster 

```sh
eksctl create cluster \
--name "$CLUSTER_NAME" \
--region "$AWS_REGION" \
--vpc-public-subnets "$DEFAULT_FOR_AZ_SUBNET" \
--with-oidc \
--ssh-access \
--ssh-public-key emr_publickey.pem \
--instance-types=m5.xlarge \
--managed
```

#### 4.4 Create namespace for Apache Spark jobs

```sh
kubectl create namespace spark-jobs
```

#### 4.5 Enable cluster access for Amazon EMR on EKS

```sh
eksctl create iamidentitymapping \
--cluster "$CLUSTER_NAME" \
--namespace spark-jobs \
--region "$AWS_REGION" \
--service-name "emr-containers"
```

#### 4.6 Create role in the spark-jobs namespace

```sh
cd ~/batch-processing-gateway-on-emr-on-eks/emr-on-eks
kubectl apply -f role.yaml
```

#### 4.7 Create rolebinding

```sh
kubectl apply -f role-binding.yaml
```

#### 4.8 Identify the ARN for the `AWSServiceRoleForAmazonEMRContainers` role

```sh
export ARN=$(aws iam get-role --role-name AWSServiceRoleForAmazonEMRContainers --region "$AWS_REGION" --query 'Role.Arn' --output text)
```

#### 4.9 Update aws-auth config map using the ARN from previous step

```sh
eksctl create iamidentitymapping \
--cluster "$CLUSTER_NAME" \
--arn "$ARN" \
--region "$AWS_REGION" \
--username emr-containers
```

#### 4.10 Get OIDC provider 
```sh
aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query "cluster.identity.oidc.issuer" --output text

```

Output will be in the format `https://oidc.eks.us-west-2.amazonaws.com/id/****************`
If the above step doesn't provide the output then Create IAM OIDC Provider using the command below 

```sh
eksctl utils associate-iam-oidc-provider --cluster "$CLUSTER_NAME" --region "$AWS_REGION" --approve
```

#### 4.11 Check if the role and attached role policy exists 

If role and role policy exists then skip step 3.12 and 3.13

```sh
aws iam get-role --role-name sparkjobrole
aws iam list-role-policies --role-name sparkjobrole
```

#### 4.12 Create an IAM role using the provided trust policy 
```sh
aws iam create-role --role-name sparkjobrole --assume-role-policy-document file://eks-trust-policy.json
```

#### 4.13 Attach the policy to the role created
```sh
aws iam put-role-policy --role-name sparkjobrole --policy-name EMR-Spark-Job-Execution --policy-document file://eks-job-role-policy.json
```

#### 4.14 Update role trust policy
```sh
aws emr-containers update-role-trust-policy --region "$AWS_REGION" --cluster-name "$CLUSTER_NAME" --namespace spark-jobs --role-name sparkjobrole
```

#### 4.15 Setup EMR on EKS cluster

```sh
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
--name ${CLUSTER_NAME}-v \
--region "$AWS_REGION" \
--container-provider "$JSON_DATA"
```

#### 5. Install Spark operator using Helm chart 

#### 5.1 Login to ECR to pull and install helm chart 

In the following command, replace the region-id values with your preferred AWS Region, and the corresponding ECR-registry-account value for the Region from the [Amazon ECR registry accounts by Region](https://docs.aws.amazon.com/emr/latest/EMR-on-EKS-DevelopmentGuide/docker-custom-images-tag.html#docker-custom-images-ECR) page.

```sh
aws ecr get-login-password \
--region "$AWS_REGION" | helm registry login \
--username AWS \
--password-stdin <ECR-REGISTRY-ACCOUNT>.dkr.ecr."$AWS_REGION".amazonaws.com
```

#### 5.2 Install Helm chart

In the following command, replace the region-id values with your preferred AWS Region, and the corresponding ECR-registry-account value for the Region from the [Amazon ECR registry accounts by Region](https://docs.aws.amazon.com/emr/latest/EMR-on-EKS-DevelopmentGuide/docker-custom-images-tag.html#docker-custom-images-ECR) page.

```sh
helm install spark-operator-demo \
oci://<ECR-REGISTRY-ACCOUNT>.dkr.ecr."$AWS_REGION".amazonaws.com/spark-operator \
--set emrContainers.awsRegion="$AWS_REGION" \
--version 7.1.0 \
--namespace spark-operator \
--create-namespace 
```

#### 5.3 Create the secret for the service account in the spark-operator namespace
```sh
kubectl apply -f  secret.yaml
```

#### 5.4 Attach the created secret to the service account
```sh
kubectl patch serviceaccount emr-containers-sa-spark-operator -n spark-operator -p '{"secrets": [{"name": "emr-containers-sa-spark-operator-token"}]}'
```

#### 5.5 Verify the successful creation of the ```spark-cluster-a-v``` and ```spark-cluster-b-v``` EMR on EKS cluster

Log in to the AWS Management Console, go to the EMR service, and click on EMR on EKS in the left-hand menu to view the virtual clusters


#### 6. (Optional) Execute Spark job in ```spark-cluster-a-v``` and ```spark-cluster-b-v``` to test the setup

Navigate to [README-Spark.md](emr-on-eks/README-Spark.md) and follow the steps to run Spark jobs.