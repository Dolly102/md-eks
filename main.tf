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
  source          = "./modules/eks"
  cluster_name    = "aamer"
  vpc_id          = module.network.vpc_id
  subnet_ids      = module.network.private_subnets
  cluster_version = "1.27"

  eks_managed_node_group_defaults = {
    ami_type       = "AL2_x86_64"
    min_size       = 1
    max_size       = 4
    desired_size   = 1
    instance_types = ["m6i.large", "m5.large", "m5n.large", "m5zn.large"]
    capacity_type  = "ON_DEMAND"
    network_interfaces = [{
      delete_on_termination       = true
      associate_public_ip_address = true
    }]
  }

  eks_managed_node_groups = {
    blue = {}
    green = {
      min_size       = 1
      max_size       = 10
      desired_size   = 1
      instance_types = ["t3.medium"]
      capacity_type  = "SPOT"
      network_interfaces = [{
        delete_on_termination       = true
        associate_public_ip_address = true
      }]
    }
  }

}
