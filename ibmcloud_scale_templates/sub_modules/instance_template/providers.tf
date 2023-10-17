terraform {
  required_providers {
    ibm = {
      source  = "IBM-Cloud/ibm"
      version = "1.54.0-sdp.2"
    }
  }
}

provider "ibm" {
  region = var.vpc_region
}
