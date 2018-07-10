#!/bin/bash

set -e

#ENV VARS
###############
SERVICE_ROLE_NAME=eksServiceRole
SERVICE_ROLE_STACK=eks-service-role
SERVICE_ROLE_FILE=eks-service-role.yaml

REGION=us-west-2

VPC_STACK_NAME=eks-service-vpc
VPC_FILE=eks-vpc-sample.yaml

CLUSTER_NAME=eks-test-cluster

NODE_GROUP_FILE=eks-nodegroup.yaml
WORKER_STACK_NAME=eks-service-worker-nodes
NODE_MIN=1
NODE_MAX=1
NODE_TYPE=t2.small
NODE_GROUP_NAME=eks-worker-group
WORKER_AMI=ami-73a6e20b
###############

printf "Configuring Auth...\n"
#export VAULT_ADDR=https://vault.jetstack.net:8200
#export VAULT_CLIENT_CERT=${HOME}/.vault-user-joshua-van-leeuwen.crt
#export VAULT_CLIENT_KEY=${HOME}/.vault-user-joshua-van-leeuwen.key
#
#vault auth -method=cert &> /dev/null
#
#DATA=$(vault read -format json "jetstack/aws/jetstack-dev/sts/admin") \
#export AWS_SECRET_ACCESS_KEY=$(printf "${DATA}" | jq -r ".data.secret_key") \
#export AWS_SESSION_TOKEN=$(printf "${DATA}" | jq -r ".data.security_token") \
#export AWS_ACCESS_KEY_ID=$(printf "${DATA}" | jq -r ".data.access_key")

#################################################

stackVariable() {
    aws cloudformation describe-stacks \
	--stack-name $1 \
	--query 'Stacks[].Outputs[? OutputKey==`'$2'`].OutputValue' \
	--out text \
    --region $REGION
}

stackExists() {
    aws cloudformation describe-stacks --stack-name $1 --region $REGION
}

function create {
    printf "Creating Cluster $CLUSTER_NAME...\n"

    printf "Configuring Service Role...\n"
    if ! aws iam get-role --role-name $SERVICE_ROLE_NAME --region $REGION &> /dev/null ; then
        printf ">>> creating eks-service-role... <<<\n"
        aws cloudformation create-stack \
            --stack-name $SERVICE_ROLE_STACK \
            --template-body file://$SERVICE_ROLE_FILE \
            --capabilities CAPABILITY_NAMED_IAM \
            --region $REGION
        aws cloudformation wait stack-create-complete --stack-name $SERVICE_ROLE_STACK --region $REGION
    fi
    SERVICE_ROLE=$(aws iam list-roles --query 'Roles[?contains(RoleName, `eksService`) ].Arn' --out text)

#################################################

    printf "Configuring VPC...\n"
    if ! stackExists $VPC_STACK_NAME &> /dev/null ; then
        printf ">>> creating VPC... <<<\n"
        aws cloudformation create-stack \
            --stack-name ${VPC_STACK_NAME} \
            --template-body file://$VPC_FILE \
            --region $REGION
        aws cloudformation wait stack-create-complete --stack-name $VPC_STACK_NAME --region $REGION
    fi
    SECURITY_GROUPS=$(stackVariable $VPC_STACK_NAME SecurityGroups)
    VPC_ID=$(stackVariable $VPC_STACK_NAME VpcId)
    SUBNET_IDS=$(stackVariable $VPC_STACK_NAME SubnetIds)

#################################################

    printf "Configuring Cluster Control Plane...\n"
    if ! aws eks describe-cluster --name $CLUSTER_NAME --region $REGION &> /dev/null ; then
    printf ">>> creating control plane: $CLUSTER_NAME... <<<\n"
        aws eks create-cluster \
            --name $CLUSTER_NAME \
            --role-arn $SERVICE_ROLE \
            --resources-vpc-config subnetIds=$SUBNET_IDS,securityGroupIds=$SECURITY_GROUPS \
            --region $REGION
    fi

    while ! aws eks describe-cluster --name $CLUSTER_NAME  --query cluster.status --out text --region $REGION | grep -q ACTIVE; do
        printf "waiting for control plane to become ready"
        sleep 2
        printf "."
        sleep 2
        printf "."
        sleep 2
        printf ".\n"
        sleep 2
    done

    ENDPOINT=$(aws eks describe-cluster --name $CLUSTER_NAME --query cluster.endpoint --region $REGION)
    CERT=$(aws eks describe-cluster --name $CLUSTER_NAME --query cluster.certificateAuthority.data --region $REGION)

#################################################

    printf "Configuring Cluster Workers...\n"

    if ! stackExists $WORKER_STACK_NAME &> /dev/null ; then
        if ! aws ec2 describe-key-pairs --key-names  ${WORKER_STACK_NAME} --region $REGION &> /dev/null; then
            printf ">>> creating key-pair... <<<\n"
            aws ec2 create-key-pair --key-name ${WORKER_STACK_NAME} --query 'KeyMaterial' --output text --region $REGION> $HOME/.ssh/id-eks.pem
            chmod 0400 $HOME/.ssh/id-eks.pem
        fi

        printf ">>> creating worker instances[$NODE_MIN - $NODE_MAX]... <<<\n"

        aws cloudformation create-stack \
            --region $REGION \
            --stack-name $WORKER_STACK_NAME  \
            --template-body file://$NODE_GROUP_FILE \
            --capabilities CAPABILITY_IAM \
            --parameters \
            ParameterKey=NodeInstanceType,ParameterValue=${NODE_TYPE} \
            ParameterKey=NodeImageId,ParameterValue=${WORKER_AMI} \
            ParameterKey=NodeGroupName,ParameterValue=${NODE_GROUP_NAME} \
            ParameterKey=NodeAutoScalingGroupMinSize,ParameterValue=${NODE_MIN} \
            ParameterKey=NodeAutoScalingGroupMaxSize,ParameterValue=${NODE_MAX} \
            ParameterKey=ClusterControlPlaneSecurityGroup,ParameterValue=${SECURITY_GROUPS} \
            ParameterKey=ClusterName,ParameterValue=${CLUSTER_NAME} \
            ParameterKey=Subnets,ParameterValue=${SUBNET_IDS//,/\\,} \
            ParameterKey=VpcId,ParameterValue=${VPC_ID} \
            ParameterKey=KeyName,ParameterValue=${WORKER_STACK_NAME}

        aws cloudformation wait stack-create-complete --stack-name $WORKER_STACK_NAME --region $REGION
    fi

    INSTANCE_ROLE=$(stackVariable $WORKER_STACK_NAME NodeInstanceRole)

#################################################

    printf "Configuring Kubeconfig\n"
    printf ">>> writing kubeconfig to ~/.kube/$CLUSTER_NAME <<<\n"
    cat >  ~/.kube/$CLUSTER_NAME <<EOF
apiVersion: v1
clusters:
- cluster:
    server: ${ENDPOINT}
    certificate-authority-data: ${CERT}
  name: kubernetes
contexts:
- context:
    cluster: kubernetes
    user: aws
  name: aws
current-context: aws
kind: Config
preferences: {}
users:
- name: aws
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1alpha1
      command: heptio-authenticator-aws
      args:
        - "token"
        - "-i"
        - "${CLUSTER_NAME}"
EOF

    export KUBECONFIG=$KUBECONFIG:~/.kube/$CLUSTER_NAME

#################################################

    printf "Configuring Worker Auth...\n"

        cat > aws-auth-cm.yaml <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: aws-auth
  namespace: kube-system
data:
  mapRoles: |
    - rolearn: ${INSTANCE_ROLE}
      username: system:node:{{EC2PrivateDNSName}}
      groups:
        - system:bootstrappers
        - system:nodes
EOF

    kubectl apply -f aws-auth-cm.yaml

    printf "Successfully Created Cluster $CLUSTER_NAME!\n"
    exit 0
}

function destroy {
    printf "\nDestroying Cluster $CLUSTER_NAME...\n"
    printf ">>> Destroying Worker Instances... <<<\n"
    aws cloudformation delete-stack --stack-name $WORKER_STACK_NAME --region $REGION
    aws cloudformation wait stack-delete-complete --stack-name $WORKER_STACK_NAME --region $REGION

    printf ">>> Destroying Control Plane... <<<\n"
    aws eks delete-cluster --name $CLUSTER_NAME --region $REGION

    printf ">>> Destroying VPC... <<<\n"
    aws cloudformation delete-stack --stack-name $VPC_STACK_NAME --region $REGION
    aws cloudformation wait stack-delete-complete --stack-name $VPC_STACK_NAME --region $REGION

    printf ">>> Destroying Service Role... <<<\n"
    aws cloudformation delete-stack --stack-name $SERVICE_ROLE_STACK --region $REGION
    aws cloudformation wait stack-delete-complete --stack-name $SERVICE_ROLE_STACK --region $REGION

    printf "Successfully Destroyed Cluster $CLUSTER_NAME!\n"
    exit 0
}

case "$1" in
    create)
        create
        ;;
    destroy)
        destroy
        ;;
    *)
        echo "Usage: $0 {create|destroy}"
        exit 1
esac
