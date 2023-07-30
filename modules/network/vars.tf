variable "name" {
  default = ""
}

variable "vpc_cidr" {
  default = ""
}

variable "azs" {
  default = ""
}

variable "private_subnets" {
  default = ""
}

variable "public_subnets" {
  default = ""
}

variable "cluster_name" {
  type    = string
  default = ""
}
