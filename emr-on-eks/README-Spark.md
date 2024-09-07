# Running Spark jobs with the Spark operator on Amazon EMR on EKS


#### 1. List ```spark-cluster-(a|b)``` contexts

```sh
kubectl config get-contexts | awk 'NR==1 || /spark-cluster-(a|b)/'
```

#### 2. Create ```spark-pi-yaml``` from ```spark-pi-template.yaml```

```sh
# Define your environment variables
export AWS_REGION="<AWS-REGION>"
export ECR_ACCOUNT="$(bash ../lookup_ecr_account.sh)"

# Use yq to replace the image value with the environment variables
yq eval ".spec.image = \"${ECR_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com/spark/emr-7.1.0:latest\"" spark-pi.template.yaml > spark-pi.yaml

```

#### 3. Run the spark job to test the successful setup of the EMR on EKS cluster

```sh
kubectl apply -f spark-pi.yaml --context "<CONTEXT_NAME>"
```

#### 4. Check events for the SparkApplication object with the following command

```sh
kubectl describe sparkapplication spark-pi --namespace spark-operator --context "<CONTEXT_NAME>"
```

#### 5. View the Driver logs to find the value of Pi

```sh 
kubectl logs spark-pi-driver --namespace spark-operator --context "<CONTEXT_NAME>"
```
If you encounter the below error, please wait for few minutes and rerun the above command. 

```
Error from server (BadRequest): container "spark-kubernetes-driver" in pod "spark-pi-driver" is waiting to start: ContainerCreating
```

After successful completion of the job, you should be able to see the below message in the logs. 

```
Pi is roughly 3.1452757263786317
```

