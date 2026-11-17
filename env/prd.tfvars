region      = "cn-north-1"
project     = "aiec"
environment = "prd"

mandatory_tags = {
  applicationname  = "AIEC Platform"
  applicationowner = "yongguo.he@astrazeneca.com"
  "Cost Center"    = "4109900005"
  "IDMD No"        = "CSE-13668"
  applicationid    = "SNSVC0008172"
  environment      = "prd"
  creationdate     = "xx/xx/2026" # Before deployment, enter the actual creation date in the format required by AZ.
}

# No automatic trigger; start builds manually or from an external pipeline.
log_retention_days = 365

# Secrets created empty by Terraform as aiec/prd/<key> (default <project>/<environment>); enter values after apply.
# tls (HTTPS certificate for all three containers): JSON keys cert / key, base64, injected as TLS_CERT / TLS_KEY.
managed_secrets = {
  tls             = "HTTPS certificate, JSON keys cert / key (base64)"
  backend-runtime = "Backend runtime configuration, incl. SSO keys SSO_TENANT_ID / SSO_CLIENT_ID / SSO_CLIENT_SECRET"
  database        = "RDS connection, JSON keys host / port / dbname / username / password"
}

# IAM roles allowed to manage the S3 and CloudWatch Logs KMS keys (rotate, disable, delete).
# The role running Terraform is added automatically; list extra AZ key administrators here if required.
kms_administrator_arns = []

# Already supplied by AZ; share subnets and the security group with DEV and PPD.
subnet_ids = [
  "subnet-8c4c1efb",
  "subnet-0886d048a9ec36d81",
]

# Run exactly two tasks per service without Auto Scaling.
# image_tag is the Docker image version, not an AWS resource tag (see mandatory_tags).
# Fill in the yyyyMMddHHmmss tag pushed by the first CodeBuild run; later builds generate their own.
services = {
  "frontend-ext" = {
    cpu           = 1024 # 1 vCPU per task, with 2 tasks
    memory        = 2048
    repository    = "az-cn-rdit-aiec-frontend-ext-prd"
    repo_url      = "https://github.com/AZU-RDIT/AIEC.git"
    buildspec     = "frontend-ext/buildspec.yml"
    branch        = "main"
    image_tag     = "REPLACE_ME_IMAGE_TAG"
    port          = 8443
    desired_count = 2

    target_group_arn = "arn:aws-cn:elasticloadbalancing:cn-north-1:REPLACE_ME:targetgroup/REPLACE_ME/REPLACE_ME"

    environment = {
      APP_ENV     = "prd"
      BACKEND_URL = "https://backend-service:8002"
    }

  }

  "frontend-int" = {
    cpu           = 1024
    memory        = 2048
    repository    = "az-cn-rdit-aiec-frontend-int-prd"
    repo_url      = "https://github.com/AZU-RDIT/AIEC.git"
    buildspec     = "frontend-int/buildspec.yml"
    branch        = "main"
    image_tag     = "REPLACE_ME_IMAGE_TAG"
    port          = 8443
    desired_count = 2

    target_group_arn = "arn:aws-cn:elasticloadbalancing:cn-north-1:REPLACE_ME:targetgroup/REPLACE_ME/REPLACE_ME"

    environment = {
      APP_ENV     = "prd"
      BACKEND_URL = "https://backend-service:8002"
    }

  }

  "backend" = {
    cpu        = 4096 # 4 vCPU per task, with 2 tasks
    memory     = 8192
    repository = "az-cn-rdit-aiec-backend-prd"
    repo_url   = "https://github.com/AZU-RDIT/AIEC.git"
    buildspec  = "backend/buildspec.yml"
    branch     = "main"

    # The backend reads and writes the application file bucket; task role permissions are generated automatically.
    file_bucket_access = true
    image_tag          = "REPLACE_ME_IMAGE_TAG"
    port               = 8002
    desired_count      = 2

    service_connect_name = "backend-service"

    # Security group rules: frontends -> 8002, egress 5432 to RDS and 443 to Entra ID / Graph.
    ingress_from_services = ["frontend-ext", "frontend-int"]
    database_access       = true
    internet_https_egress = true

    # Without an ALB health check, the container health check is the only health signal.
    # -k skips self-signed certificate verification; curl must be installed in the image.
    health_check_command = "curl -fsSk https://localhost:8002/health || exit 1"

    environment = {
      APP_ENV = "prd"
    }

    # Map environment variable names to secrets; execution role access is scoped to the referenced secrets automatically.
    # TLS is injected from managed_secrets.tls; do not repeat it here.
    # "secret" injects the whole JSON; "secret:json-key" injects one key. Names must match the application code.
    secrets = {
      BACKEND_RUNTIME   = "backend-runtime"
      DB_HOST           = "database:host"
      DB_PORT           = "database:port"
      DB_NAME           = "database:dbname"
      DB_USERNAME       = "database:username"
      DB_PASSWORD       = "database:password"
      SSO_TENANT_ID     = "backend-runtime:SSO_TENANT_ID"
      SSO_CLIENT_ID     = "backend-runtime:SSO_CLIENT_ID"
      SSO_CLIENT_SECRET = "backend-runtime:SSO_CLIENT_SECRET"
    }

    # If these secrets use a CMK, also specify:
    # secrets_kms_key_arns = ["arn:aws-cn:kms:cn-north-1:332091793104:key/<key-id>"]
  }
}
