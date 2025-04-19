#https://github.com/terraform-yc-modules/terraform-yc-kubernetes/blob/master/variables.tf
terraform {
  backend "s3" {
    region = "ru-central1"
    endpoints = {
      s3 = "https://storage.yandexcloud.net"
    }

    bucket = "yds-terraform-state-backend"
    //dynamodb_table = "yds-terraform-state-locks"
    use_lockfile                = true
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true # This option is required for Terraform 1.6.1 or higher.
    skip_metadata_api_check     = true
    //skip_s3_checksum            = true # This option is required to describe a backend for Terraform version 1.6.3 or higher.
    //encrypt                     = true

    key = "kube/addons/terraform.tfstate"
  }

  required_providers {
    yandex = {
      source = "yandex-cloud/yandex"
    }

    kubectl = {
      source = "gavinbunney/kubectl"
    }
  }

  required_version = ">= 0.13"
}

provider "yandex" {
  folder_id = var.folder_id
  zone      = var.yds_region
}

data "terraform_remote_state" "kube" {
  backend = "s3"
  config = {
    region = "ru-central1"
    endpoints = {
      s3 = "https://storage.yandexcloud.net"
    }
    bucket                      = "yds-terraform-state-backend"
    key                         = "kube/terraform.tfstate"
    skip_region_validation      = true
    skip_credentials_validation = true
    skip_requesting_account_id  = true # This option is required for Terraform 1.6.1 or higher.
    skip_s3_checksum            = true # This option is required to describe a backend for Terraform version 1.6.3 or higher.
  }
}

module "addons" {
  source = "github.com/terraform-yc-modules/terraform-yc-kubernetes-marketplace"

  cluster_id = data.terraform_remote_state.kube.outputs.cluster_id

  install_ingress_nginx = true

  # Full usage example:
  # https://github.com/terraform-yc-modules/terraform-yc-kubernetes-marketplace/tree/main/examples/full
}

#https://registry.terraform.io/providers/yandex-cloud/yandex/latest/docs/data-sources/client_config
data "yandex_client_config" "this" {}

provider "kubernetes" {
  host                   = data.terraform_remote_state.kube.outputs.external_v4_endpoint
  cluster_ca_certificate = data.terraform_remote_state.kube.outputs.cluster_ca_certificate
  token                  = data.yandex_client_config.this.iam_token
  load_config_file       = false
}

provider "helm" {
  kubernetes {
    host                   = data.terraform_remote_state.kube.outputs.external_v4_endpoint
    cluster_ca_certificate = data.terraform_remote_state.kube.outputs.cluster_ca_certificate
    token                  = data.yandex_client_config.this.iam_token
  }
  debug = true
}

provider "kubectl" {
  host                   = data.terraform_remote_state.kube.outputs.external_v4_endpoint
  cluster_ca_certificate = data.terraform_remote_state.kube.outputs.cluster_ca_certificate
  token                  = data.yandex_client_config.this.iam_token
  load_config_file       = false
}

data "http" "cert-manager-crd" {
  url = "https://github.com/cert-manager/cert-manager/releases/download/v1.12.16/cert-manager.crds.yaml"
}

data "kubectl_file_documents" "docs" {
  content = data.http.cert-manager-crd.response_body
}

//https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs#installation
resource "kubectl_manifest" "cert-manager-crd" {
  for_each  = data.kubectl_file_documents.docs.manifests
  yaml_body = each.value
}

//example via terraform https://github.com/cert-manager/cert-manager/issues/7369
resource "helm_release" "jetstack" {
  name       = "cert-manager"
  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  namespace  = "cert-manager"
  version    = "v1.12.16"
  depends_on = [
    kubectl_manifest.cert-manager-crd
  ]
  create_namespace = true
  wait             = true
  replace          = true
  timeout          = 90
  #not works
  set {
    name  = "crds.enabled"
    value = true
  }

  set {
    name  = "crds.keep"
    value = false
  }
}

resource "helm_release" "rancher" {
  #  depends_on       = [helm_release.cert-manager, time_sleep.wait_for_cert_manager]
  depends_on = [
    helm_release.jetstack,
    module.addons
  ]

  name             = "rancher"
  repository       = "https://releases.rancher.com/server-charts/stable"
  chart            = "rancher"
  version          = "v2.10.3"
  namespace        = "cattle-system"
  create_namespace = true
  wait             = true
  replace          = true
  timeout          = 600

  set {
    name  = "hostname"
    value = "rancher-yc.zerotech.ru"
  }

  /*set {
    name  = "antiAffinity"
    value = length(var.cluster_nodes) == 1 ? "preffered" : "required"
  }*/
  set {
    name  = "ingress.ingressClassName"
    value = "nginx"
  }

  set {
    name  = "replicas"
    value = "-1"
  }

  set {
    name  = "bootstrapPassword"
    value = "4HEDlokuRcA6elqt"
  }

  //set-string ingress.extraAnnotations.'nginx\.ingress\.kubernetes\.io/ssl-redirect'="false"
}
