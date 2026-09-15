#!/bin/bash
set -e

# Check if environment parameter is provided
if [ $# -eq 0 ]; then
    echo "❌ Error: Environment parameter is required"
    echo "Usage: $0 <environment>"
    echo "Example: $0 dev"
    echo "Available environments: dev, test, prod"
    exit 1
fi

ENVIRONMENT=$1
PROJECT_NAME=${2:-twin}

EXPECTED_ACCOUNT="221759618907"

# Pin the CLI and Terraform to the same credentials. Falls through to the
# ambient chain (env vars, instance role) on machines without a twin profile.
if [ -z "${AWS_PROFILE:-}" ] && aws configure list-profiles 2>/dev/null | grep -qx "twin"; then
  export AWS_PROFILE=twin
fi

# Must run before anything touches S3 - the aws s3 rm calls below bypass
# Terraform, so its allowed_account_ids guard would fire too late.
ACTUAL_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
if [ "$ACTUAL_ACCOUNT" != "$EXPECTED_ACCOUNT" ]; then
  echo "❌ Wrong AWS account: $ACTUAL_ACCOUNT (expected $EXPECTED_ACCOUNT)" >&2
  echo "   AWS_PROFILE=${AWS_PROFILE:-<unset>}" >&2
  exit 1
fi

echo "🗑️ Preparing to destroy ${PROJECT_NAME}-${ENVIRONMENT} infrastructure..."

# Navigate to terraform directory
cd "$(dirname "$0")/../terraform"

# Get AWS Account ID and Region for backend configuration
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=${DEFAULT_AWS_REGION:-us-east-1}

# Initialize terraform with S3 backend
echo "🔧 Initializing Terraform with S3 backend..."
terraform init -input=false \
  -backend-config="bucket=twin-terraform-state-${AWS_ACCOUNT_ID}" \
  -backend-config="key=${ENVIRONMENT}/terraform.tfstate" \
  -backend-config="region=${AWS_REGION}" \
  -backend-config="dynamodb_table=twin-terraform-locks" \
  -backend-config="encrypt=true"


# Check if workspace exists
if ! terraform workspace list | grep -qE "^[* ] +${ENVIRONMENT}$"; then
    echo "❌ Error: Workspace '$ENVIRONMENT' does not exist"
    echo "Available workspaces:"
    terraform workspace list
    exit 1
fi

# Select the workspace
terraform workspace select "$ENVIRONMENT"

echo ""
echo "⚠️  Permanently deleting all ${PROJECT_NAME}-${ENVIRONMENT} resources in"
echo "    account ${ACTUAL_ACCOUNT}, including every stored conversation."

echo "📦 Emptying S3 buckets..."

# Read bucket names from state so they cannot drift from main.tf's naming
FRONTEND_BUCKET=$(terraform output -raw s3_frontend_bucket 2>/dev/null || true)
MEMORY_BUCKET=$(terraform output -raw s3_memory_bucket 2>/dev/null || true)

# Empty frontend bucket if it exists
if [ -n "$FRONTEND_BUCKET" ] && aws s3 ls "s3://$FRONTEND_BUCKET" 2>/dev/null; then
    echo "  Emptying $FRONTEND_BUCKET..."
    aws s3 rm "s3://$FRONTEND_BUCKET" --recursive
else
    echo "  Frontend bucket not found or already empty"
fi

# Empty memory bucket if it exists
if [ -n "$MEMORY_BUCKET" ] && aws s3 ls "s3://$MEMORY_BUCKET" 2>/dev/null; then
    echo "  Emptying $MEMORY_BUCKET..."
    aws s3 rm "s3://$MEMORY_BUCKET" --recursive
else
    echo "  Memory bucket not found or already empty"
fi

echo "🔥 Running terraform destroy..."

# Create a dummy lambda zip if it doesn't exist (needed for destroy in GitHub Actions)
if [ ! -f "../backend/lambda-deployment.zip" ]; then
    echo "Creating dummy lambda package for destroy operation..."
    echo "dummy" | zip ../backend/lambda-deployment.zip -
fi

# Run terraform destroy with auto-approve
if [ "$ENVIRONMENT" = "prod" ] && [ -f "prod.tfvars" ]; then
    terraform destroy -var-file=prod.tfvars -var="project_name=$PROJECT_NAME" -var="environment=$ENVIRONMENT" -auto-approve
else
    terraform destroy -var="project_name=$PROJECT_NAME" -var="environment=$ENVIRONMENT" -auto-approve
fi

echo "✅ Infrastructure for ${ENVIRONMENT} has been destroyed!"
echo ""
echo "💡 To remove the workspace completely, run:"
echo "   terraform workspace select default"
echo "   terraform workspace delete $ENVIRONMENT"