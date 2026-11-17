region      = "cn-north-1"
project     = "aiec"
environment = "dev"

# AZ mandatory tags. project controls resource names; applicationname is the application display name.
mandatory_tags = {
  applicationname  = "AIEC Platform"
  applicationowner = "yongguo.he@astrazeneca.com"
  "Cost Center"    = "4109900005"
  "IDMD No"        = "CSE-13668"
  applicationid    = "SNSVC0008172"
  environment      = "dev"
  creationdate     = "11/11/2026" # Before deployment, enter the actual creation date in the format required by AZ.
}

# Builds are triggered manually or by an external pipeline; a separate release process deploys ECS.
log_retention_days = 365

# Secrets created empty by Terraform as <secret_name_prefix>/<key>; enter values after apply.
secret_name_prefix = "aiec/personal"

# tls (HTTPS certificate for all three containers): JSON keys cert / key, base64, injected as TLS_CERT / TLS_KEY.
managed_secrets = {
  tls             = "HTTPS certificate, JSON keys cert / key (base64)"
  backend-runtime = "Backend runtime configuration, incl. SSO keys SSO_TENANT_ID / SSO_CLIENT_ID / SSO_CLIENT_SECRET"
  database        = "RDS connection, JSON keys host / port / dbname / username / password"
}

# IAM roles allowed to manage the S3 and CloudWatch Logs KMS keys (rotate, disable, delete).
# Must include the role that runs Terraform, otherwise AWS rejects the key policy.
kms_administrator_arns = [
  "arn:aws-cn:iam::332091793104:role/REPLACE_ME", # replace with the AZ key administrator and the actual deployment role
]

# Private subnets supplied by AZ; all three environments currently share these two subnets and the configured service security group.
subnet_ids = [
  "subnet-8c4c1efb",
  "subnet-0886d048a9ec36d81",
]

# The map key is both the service and container name and forms resource names: az-cn-rdit-<project>-<service>-dev.
# AZ creates and supplies security_group_ids and target_group_arn.
# All three services share one Git repository; buildspec paths are relative to the repository root.
# repository is the service's ECR image repository name, not a Git repository or source directory.
# image_tag is the Docker image version, not an AWS resource tag (see mandatory_tags).
# Fill in the yyyyMMddHHmmss tag pushed by the first CodeBuild run; later builds generate their own.
services = {
  "frontend-ext" = {
    cpu           = 512 # 0.5 vCPU
    memory        = 1024
    repository    = "az-cn-rdit-aiec-frontend-ext-dev"
    repo_url      = "https://github.com/AZU-RDIT/AIEC.git"
    buildspec     = "frontend-ext/buildspec.yml" # External frontend
    branch        = "dev"
    image_tag     = "REPLACE_ME_IMAGE_TAG"
    port          = 8443
    desired_count = 1

    security_group_ids = ["sg-0960c20f67f17cb68"]
    target_group_arn   = "arn:aws-cn:elasticloadbalancing:cn-north-1:REPLACE_ME:targetgroup/REPLACE_ME/REPLACE_ME"

    environment = {
      APP_ENV     = "dev"
      BACKEND_URL = "https://backend-service:8002"
    }

  }

  "frontend-int" = {
    cpu           = 512
    memory        = 1024
    repository    = "az-cn-rdit-aiec-frontend-int-dev"
    repo_url      = "https://github.com/AZU-RDIT/AIEC.git"
    buildspec     = "frontend-int/buildspec.yml" # Internal frontend
    branch        = "dev"
    image_tag     = "REPLACE_ME_IMAGE_TAG"
    port          = 8443
    desired_count = 1

    security_group_ids = ["sg-0960c20f67f17cb68"]
    target_group_arn   = "arn:aws-cn:elasticloadbalancing:cn-north-1:REPLACE_ME:targetgroup/REPLACE_ME/REPLACE_ME"

    environment = {
      APP_ENV     = "dev"
      BACKEND_URL = "https://backend-service:8002"
    }

  }

  "backend" = {
    cpu        = 2048 # 2 vCPU
    memory     = 4096
    repository = "az-cn-rdit-aiec-backend-dev"
    repo_url   = "https://github.com/AZU-RDIT/AIEC.git"
    buildspec  = "backend/buildspec.yml" # Backend

    # The backend reads and writes the application file bucket; task role permissions are generated automatically.
    file_bucket_access = true
    branch             = "dev"
    image_tag          = "REPLACE_ME_IMAGE_TAG"
    port               = 8002
    desired_count      = 1

    security_group_ids   = ["sg-0960c20f67f17cb68"]
    service_connect_name = "backend-service"

    # Without an ALB health check, the container health check is the only health signal.
    # -k skips self-signed certificate verification; curl must be installed in the image.
    health_check_command = "curl -fsSk https://localhost:8002/health || exit 1"

    environment = {
      APP_ENV = "dev"
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
