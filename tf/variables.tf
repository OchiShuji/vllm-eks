variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-northeast-1"
}

variable "domain_name" {
  description = "Domain name for the ACM certificate"
  type        = string
  default     = "vllm.consulting-io.com"
}

variable "hf_token" {
  description = "Hugging Face token — pass via TF_VAR_hf_token env var, never hardcode"
  type        = string
  sensitive   = true
}

variable "node_role_name" {
  description = "IAM role name created by eksctl for EKS Auto Mode nodes"
  type        = string
  default     = "eksctl-vllm-cluster-cluster-AutoModeNodeRole-vl1nYpksyusp"
}
