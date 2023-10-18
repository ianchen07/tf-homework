## Declare variables
variable "region" {
  description = "AWS Region"
  type        = string
  default     = "ap-southeast-2"
}

variable "cluster_name" {
  description = "ECS Fargate cluster name"
  type        = string
  default     = "ian-test"
}

variable "app_name" {
  description = "Application name"
  type        = string
  default     = "nginx"
}

variable "image_uri" {
  description = "Task docker image uri"
  type        = string
  default     = "nginx:latest"
}

variable "container_port" {
  description = "On which port the app is exposed"
  type        = string
  default     = "80"
}

variable "r53_zone" {
  description = "Name of the R53 zone"
  type        = string
}
