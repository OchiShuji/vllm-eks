output "acm_certificate_arn" {
  description = "ARN of the validated ACM certificate — use this as acm_certificate_arn in the ALB Ingress"
  value       = aws_acm_certificate_validation.this.certificate_arn
}
