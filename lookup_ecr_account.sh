#!/bin/bash
set -eou pipefail

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - #
# F   U   N   C    T    I    O    N    S
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - #


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

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - #
# M   A   I   N
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - #

# AWS Region
aws_region=$AWS_REGION
# Check for errors
if [ -z "$aws_region" ]; then
  echo "AWS_REGION is not set. Set the AWS_REGION value in the shell. Exiting."
  exit 0
fi

ecr_account=$(lookup_ecr_account "$aws_region")
echo "$ecr_account"