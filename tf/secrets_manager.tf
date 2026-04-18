resource "aws_secretsmanager_secret" "hf_token" {
  name = "vllm-cluster/hf-token"
}

resource "aws_secretsmanager_secret_version" "hf_token" {
  secret_id     = aws_secretsmanager_secret.hf_token.id
  secret_string = var.hf_token
}
