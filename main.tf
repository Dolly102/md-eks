terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.10.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.10.1"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
  }
  backend "s3" {
    bucket                 = "abyaz-tf-state"
    key                    = "abyaz.tf"
    region                 = "ap-south-2"
    encrypt                = true
    profile                = "sia"
    dynamodb_table         = "dev-abyaz-tf-state-locking"
    skip_region_validation = true
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

provider "aws" {
  region  = "ap-south-2"
  profile = "sia"
  default_tags {
    tags = {
      Project   = "EKS"
      ManagedBy = "Aamer"
      Company   = "Primesoft Inc"
      Location  = "Hyderabad"
    }
  }
}

locals {
  vpc_cidr        = "171.23.0.0/16"
  azs             = slice(data.aws_availability_zones.available.names, 0, 3)
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 4)]
}

module "network" {
  source          = "./modules/network"
  name            = "eks-vpc"
  cluster_name    = "aamer"
  vpc_cidr        = local.vpc_cidr
  azs             = local.azs
  private_subnets = local.private_subnets
  public_subnets  = local.public_subnets
}

module "eks" {
  source = "./modules/eks"
  vpc_id = module.network.vpc_id

  subnet_ids      = module.network.private_subnets
  cluster_name    = "aamer"
  cluster_version = "1.27"

  eks_managed_node_groups = {
    "eks-ondemand" = {
      ami_type     = "AL2_x86_64"
      min_size     = 1
      max_size     = 4
      desired_size = 1
      disk_size    = 60
      instance_types = [
        "m5.xlarge",
        "t3.xlarge"
      ]
      capacity_type = "ON_DEMAND"
      network_interfaces = [{
        delete_on_termination       = true
        associate_public_ip_address = true
      }]
    }
  }

}

data "aws_eks_cluster" "cluster" {
  name = module.eks.cluster_name
}

data "aws_eks_cluster_auth" "cluster" {
  name = module.eks.cluster_name
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.cluster.token
  }
}

module "cert_manager_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5"

  role_name                     = "cert-manager"
  attach_cert_manager_policy    = true
  cert_manager_hosted_zone_arns = ["arn:aws:route53:::hostedzone/Z0411043ISXL599QGTOU"]

  oidc_providers = {
    eks = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:cert-manager"]
    }
  }
}

module "external_dns_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5"

  role_name                     = "external-dns"
  attach_external_dns_policy    = true
  external_dns_hosted_zone_arns = ["arn:aws:route53:::hostedzone/Z0411043ISXL599QGTOU"]

  oidc_providers = {
    eks = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:external-dns"]
    }
  }
}

resource "helm_release" "cert-manager" {
  name       = "cert-manager"
  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  namespace  = "cert-manager"

  create_namespace = false

  set {
    name  = "wait-for"
    value = module.cert_manager_irsa_role.iam_role_arn
  }

  set {
    name  = "installCRDs"
    value = "true"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com\\/role-arn"
    value = module.cert_manager_irsa_role.iam_role_arn
  }

  values = [
    "${file("modules/helm/templates/values-cert-manager.yaml")}"
  ]
}

resource "helm_release" "external-dns" {
  name       = "external-dns"
  repository = "https://charts.bitnami.com/bitnami"
  chart      = "external-dns"
  namespace  = "kube-system"

  create_namespace = false

  set {
    name  = "wait-for"
    value = module.external_dns_irsa_role.iam_role_arn
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com\\/role-arn"
    value = module.external_dns_irsa_role.iam_role_arn
  }

  set {
    name  = "policy"
    value = "sync"
  }

  values = [
    "${file("modules/helm/templates/values-external-dns.yaml")}"
  ]
}

resource "helm_release" "nginx-ingress" {
  name       = "nginx-ingress"
  repository = "https://helm.nginx.com/stable"
  chart      = "nginx-ingress"
  namespace  = "ingress"

  create_namespace = false
}
