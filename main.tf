terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.59.0"
    }

    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.9.0"
    }

    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.18.1"
    }
  }
}

provider "aws" {
  profile = "foo-dev"
  region  = "us-east-1"
}


locals {
  cluster_name = "foo"
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    # This requires the awscli to be installed locally where Terraform is executed
    args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--profile", "foo-dev"]
  }
}

data "aws_availability_zones" "available" {}

module "eks-kubeconfig" {
  source     = "hyperbadger/eks-kubeconfig/aws"
  version    = "2.0.0"
  depends_on = [module.eks]

  cluster_name = module.eks.cluster_name
}

resource "local_file" "kubeconfig" {
  content  = module.eks-kubeconfig.kubeconfig
  filename = "kubeconfig_${local.cluster_name}"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "3.19.0"

  name = "foo-vpc"

  cidr = "10.0.0.0/16"
  azs  = slice(data.aws_availability_zones.available.names, 0, 3)

  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.4.0/24", "10.0.5.0/24", "10.0.6.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  public_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                      = 1
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"             = 1
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "19.10.1"

  cluster_name    = local.cluster_name
  cluster_version = "1.25"

  vpc_id                         = module.vpc.vpc_id
  subnet_ids                     = module.vpc.private_subnets
  cluster_endpoint_public_access = true

  eks_managed_node_group_defaults = {
    ami_type = "AL2_x86_64"
  }

  eks_managed_node_groups = {
    first = {
      name = "node-group-1"

      instance_type = "t3.small"

      min_size     = 1
      max_size     = 1
      desired_size = 1
    }
  }
}

resource "kubernetes_namespace" "foo" {
  metadata {
    name = "dev-foo"
  }
}

resource "kubernetes_deployment" "foo" {
  metadata {
    name = "foo-deployment"
    labels = {
      app = "foo"
    }
    namespace = "dev-foo"
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "foo"
      }
    }
    template {
      metadata {
        labels = {
          app = "foo"
        }
      }
      spec {
        container {
          image             = "nginxdemos/hello"
          image_pull_policy = "IfNotPresent"
          name              = "foo"
          port {
            container_port = 80
          }
          resources {
            limits = {
              cpu    = "0.5"
              memory = "512Mi"
            }
            requests = {
              cpu    = "250m"
              memory = "50Mi"
            }
          }
        }
        dynamic "image_pull_secrets" {
          for_each = false ? toset([]) : toset([1])
          content {
            name = ""
          }
        }
      }
    }
  }
}
