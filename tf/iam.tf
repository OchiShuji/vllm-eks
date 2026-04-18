# The node role is created by eksctl (CloudFormation).
# Run `eksctl create cluster -f ../cluster.yaml` before `terraform apply`.
data "aws_iam_role" "node_role" {
  name = var.node_role_name
}

resource "aws_iam_role_policy" "hf_token_secrets_manager" {
  name = "vllm-hf-token-secrets-manager"
  role = data.aws_iam_role.node_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = aws_secretsmanager_secret.hf_token.arn
    }]
  })
}
