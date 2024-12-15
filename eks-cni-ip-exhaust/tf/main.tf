provider "aws" {
  region = "ap-south-1"
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.eks.token
}

locals {
  cluster_name = "eks-auto-mode-cluster"
  vpc_cidr     = "10.0.0.0/16"
  public_subnet_cidrs = ["10.0.105.0/24", "10.0.106.0/24"]
  tags = {
    "Name"        = "eks-auto-mode"
    "Environment" = "test"
  }
}


module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.0.0"

  name           = "eks-auto-vpc"
  cidr           = local.vpc_cidr
  azs            = ["ap-south-1a", "ap-south-1b"]
  public_subnets = local.public_subnet_cidrs

  enable_nat_gateway = false

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  map_public_ip_on_launch = true

  tags = local.tags
}

module "eks_sg" {
  source = "terraform-aws-modules/security-group/aws"
  name   = "eks-sg"
  vpc_id = module.vpc.vpc_id

  egress_rules = ["all-all"] # Allow all outbound traffic

  tags = local.tags
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.31.1"

  cluster_name                   = local.cluster_name
  cluster_version                = "1.29"
  cluster_endpoint_public_access = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.public_subnets

  enable_cluster_creator_admin_permissions = true

  tags = local.tags
}

resource "aws_eks_node_group" "workers" {
  cluster_name    = module.eks.cluster_name
  node_group_name = "workers"

  node_role_arn = aws_iam_role.eks_worker_role.arn
  subnet_ids    = module.vpc.public_subnets

  scaling_config {
    desired_size = 2
    max_size     = 3
    min_size     = 1
  }

  instance_types = ["t3.medium"]

  tags = local.tags
}

resource "kubernetes_config_map" "aws_vpc_cni" {
  metadata {
    name      = "aws-node"
    namespace = "kube-system"
  }

  data = {
    "AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG" = "true"
    "ENABLE_PREFIX_DELEGATION"           = "false"
    "WARM_IP_TARGET"                     = "0"
    "MINIMUM_IP_TARGET"                  = "1"
  }

  depends_on = [module.eks]
}

resource "kubernetes_deployment" "ip_exhaustion_simulation" {
  metadata {
    name      = "ip-exhaustion"
    namespace = "default"
  }

  spec {
    replicas = 50

    selector {
      match_labels = {
        app = "ip-exhaustion"
      }
    }

    template {
      metadata {
        labels = {
          app = "ip-exhaustion"
        }
      }

      spec {
        container {
          name  = "nginx"
          image = "nginx:latest"

          resources {
            requests = {
              cpu    = "10m"
              memory = "16Mi"
            }
            limits = {
              cpu    = "50m"
              memory = "64Mi"
            }
          }
        }
      }
    }
  }

  depends_on = [kubernetes_config_map.aws_vpc_cni]
}


data "aws_eks_cluster_auth" "eks" {
  name = module.eks.cluster_name
}


# Create an IAM Role
resource "aws_iam_role" "eks_role" {
  name               = "eks_full_access_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = [
            "eks.amazonaws.com"
          ]
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

# Attach AWS Managed Policies
resource "aws_iam_role_policy_attachment" "eks_ec2_permissions" {
  role       = aws_iam_role.eks_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  role       = aws_iam_role.eks_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "iam_permissions" {
  role       = aws_iam_role.eks_role.name
  policy_arn = "arn:aws:iam::aws:policy/IAMFullAccess"
}

resource "aws_iam_role" "eks_worker_role" {
  name               = "eks_worker_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "worker_node_policies" {
  count      = length(["AmazonEKSWorkerNodePolicy", "AmazonEC2ContainerRegistryReadOnly", "AmazonEKS_CNI_Policy"])
  role       = aws_iam_role.eks_worker_role.name
  policy_arn = element([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  ], count.index)
}

