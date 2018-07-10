# EKS Support for Tarmak

## EKS EKS is Amazons venture into delivering automated Kubernetes deployments.
EKS provides a 'control plane' consisting of master nodes spread over multiple
availability zones with a single endpoint that kubectl and workers connect to.

## AWS Identity and Access Management (IAM Roles)
Amazon use 'IAM Roles' to authenticate and authorize actions on resources in the
AWS world. Since the master plane needs to create resources on AWS, it needs to
be provided with IAM polices that can create these resources on your behalf.
[Here](https://docs.aws.amazon.com/eks/latest/userguide/service_IAM_role.html)
is the default list of roles needed by EKS to function.

## Steps
### 1. Create Service Roles:
Firstly the service role needs to be created for EKS to make all the resources
on your behalf. (A service role is an IAM role which is assumed by a service to
perform actions on your behalf.


### 2. Create Virtual Private Cloud (VPC)
The Kubernetes cluster instances will all sit inside a VPC including the control
plane. Amazon EKS requires that there exists subnets in at least two different
availability zones.

### 3. Create Master Control Plane

## Negatives (There are a lot.)
- Big development investment
- It's very new in development stage, only became GA recently. This means lots
  can change and cause extra work through breaking changes etc.
- Limited regions available (only us-west-2 and us-east-1)
- Limited Kubernetes master version available as well as no access to binary so
  no feature flags etc.
- No access to the master instances.

--
EKS support for Tarmak represents a significant development investment as well
providing less features than currently supported with Tarmak's single current
supported 'provider' (vanilla AWS). Unless a very large customer interest
exists, I do not think we should push support within Tarmak _at this current
time_.
