Dear sir/madam,

1. This main.tf has all resources in it, I am not splitting resources into multiple tf files to make it easy to read.
2. I have implemented below features to ensure scalability/reliability/security:
  - running in ECS Fargate cluster so that no need to manage nodes
  - ALB healthcheck will ensure Number of desire_count:1 tasks will always be running, we could raise the no. if we need to scale it horizontally
  - we could also pass in a bigger value of cpu and mem to scale it vertically
  - service and ALB all in multiple AZs which ensures high-availability
  - the task container only accepts request from ALB port 80, and the ALB only accepts request from port 80 and 443 public.
  - last but most importantly, we use https LB listener, which ensure http/https access from public will all go through https listener which is attached with an ACM certificate, then it can reach the target group which is the ECS task
3. The "Creat ACM certificate" part realised automation of creating and validating a cert.
4. In this workshop I used default VPC and public subnets in my account, referred to them in tf using data blocks.
