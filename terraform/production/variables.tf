variable "environment" {
  type    = string
  default = "dev"
}

variable "db_url_seceret_arn" {
  type    = string
  default = "arn:aws:secretsmanager:us-east-1:123456789012:secret:example"
}

variable "container_registry" {
  description = "The registry where container images are stored"
  type        = string
  default     = "ghcr.io"
}

variable "namespace" {
  description = "The namespace for the container images"
  type        = string
  default     = "baumstern"
}

variable "api_image_name" {
  description = "The name of the API container image"
  type        = string
  default     = "api"
}

variable "api_image_tag" {
  description = "The tag for the API container image to use"
  type        = string
  default     = "latest"
}

variable "dashboard_image_name" {
  description = "The name of the dashboard container image"
  type        = string
  default     = "dashboard"
}

variable "dashboard_image_tag" {
  description = "The tag for the dashboard container image to use"
  type        = string
  default     = "latest"
}

variable "client_image_name" {
  description = "The name of the client container image"
  type        = string
  default     = "client"
}

variable "client_image_tag" {
  description = "The tag for the client container image to use"
  type        = string
  default     = "latest"
}
