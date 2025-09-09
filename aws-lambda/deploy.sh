#!/bin/bash

# OpenAI Compliance Backup Deployment Script
# This script deploys the AWS infrastructure and Lambda function

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.json"
STACK_NAME="openai-compliance-backup-stack"
TEMPLATE_FILE="$SCRIPT_DIR/cloudformation-template.yaml"
LAMBDA_ZIP="$SCRIPT_DIR/lambda-deployment-package.zip"

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if AWS CLI is installed
check_aws_cli() {
    if ! command -v aws &> /dev/null; then
        print_error "AWS CLI is not installed. Please install it first."
        exit 1
    fi
}

# Function to check AWS credentials
check_aws_credentials() {
    if ! aws sts get-caller-identity &> /dev/null; then
        print_error "AWS credentials not configured. Run 'aws configure' first."
        exit 1
    fi
}

# Function to create Lambda deployment package
create_lambda_package() {
    print_status "Creating Lambda deployment package..."
    
    # Create temporary directory
    TEMP_DIR=$(mktemp -d)
    
    # Copy Lambda function and requirements
    cp "$SCRIPT_DIR/lambda_function.py" "$TEMP_DIR/"
    cp "$SCRIPT_DIR/requirements.txt" "$TEMP_DIR/"
    
    # Install dependencies (try uv first, then pip3, then pip)
    cd "$TEMP_DIR"
    if command -v uv &> /dev/null; then
        print_status "Using uv to install dependencies..."
        uv pip install -r requirements.txt --target .
    elif command -v pip3 &> /dev/null; then
        print_status "Using pip3 to install dependencies..."
        pip3 install -r requirements.txt -t .
    elif command -v pip &> /dev/null; then
        print_status "Using pip to install dependencies..."
        pip install -r requirements.txt -t .
    else
        print_error "No Python package manager found (uv, pip3, or pip)"
        print_error "Please install one of them to create the Lambda deployment package"
        rm -rf "$TEMP_DIR"
        exit 1
    fi
    
    # Create ZIP file
    zip -r "$LAMBDA_ZIP" .
    
    # Cleanup
    rm -rf "$TEMP_DIR"
    cd "$SCRIPT_DIR"
    
    print_success "Lambda deployment package created: $LAMBDA_ZIP"
}

# Function to validate parameters
validate_parameters() {
    if [ -z "$OPENAI_API_KEY" ]; then
        print_error "OPENAI_API_KEY environment variable is required"
        exit 1
    fi
    
    if [ -z "$WORKSPACE_ID" ]; then
        print_error "WORKSPACE_ID environment variable is required"
        exit 1
    fi
}

# Function to deploy CloudFormation stack
deploy_stack() {
    print_status "Deploying CloudFormation stack..."
    
    local bucket_name="${S3_BUCKET_NAME:-openai-compliance-backup}"
    local schedule="${BACKUP_SCHEDULE:-cron(0 2 * * ? *)}"
    
    aws cloudformation deploy \
        --template-file "$TEMPLATE_FILE" \
        --stack-name "$STACK_NAME" \
        --parameter-overrides \
            OpenAIAPIKey="$OPENAI_API_KEY" \
            WorkspaceID="$WORKSPACE_ID" \
            S3BucketName="$bucket_name" \
            BackupSchedule="$schedule" \
        --capabilities CAPABILITY_NAMED_IAM \
        --region "${AWS_REGION:-us-east-1}"
    
    print_success "CloudFormation stack deployed successfully"
}

# Function to update Lambda function code
update_lambda_code() {
    print_status "Updating Lambda function code..."
    
    local function_name=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --query 'Stacks[0].Outputs[?OutputKey==`LambdaFunctionName`].OutputValue' \
        --output text \
        --region "${AWS_REGION:-us-east-1}")
    
    aws lambda update-function-code \
        --function-name "$function_name" \
        --zip-file "fileb://$LAMBDA_ZIP" \
        --region "${AWS_REGION:-us-east-1}"
    
    print_success "Lambda function code updated"
}

# Function to test the deployment
test_deployment() {
    print_status "Testing deployment..."
    
    local function_name=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --query 'Stacks[0].Outputs[?OutputKey==`LambdaFunctionName`].OutputValue' \
        --output text \
        --region "${AWS_REGION:-us-east-1}")
    
    print_status "Invoking Lambda function with test payload..."
    
    echo '{"test": true}' > /tmp/test-payload.json
    aws lambda invoke \
        --function-name "$function_name" \
        --payload fileb:///tmp/test-payload.json \
        --region "${AWS_REGION:-us-east-1}" \
        /tmp/lambda-response.json
    
    if [ $? -eq 0 ]; then
        print_success "Test invocation successful"
        echo "Response:"
        cat /tmp/lambda-response.json
        echo
    else
        print_error "Test invocation failed"
        exit 1
    fi
}

# Function to display stack outputs
show_outputs() {
    print_status "Stack outputs:"
    
    aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' \
        --output table \
        --region "${AWS_REGION:-us-east-1}"
}

# Function to setup SNS notifications (optional)
setup_notifications() {
    if [ -n "$EMAIL_NOTIFICATION" ]; then
        print_status "Setting up email notifications..."
        
        local sns_topic_arn=$(aws cloudformation describe-stacks \
            --stack-name "$STACK_NAME" \
            --query 'Stacks[0].Outputs[?OutputKey==`SNSTopicArn`].OutputValue' \
            --output text \
            --region "${AWS_REGION:-us-east-1}")
        
        aws sns subscribe \
            --topic-arn "$sns_topic_arn" \
            --protocol email \
            --notification-endpoint "$EMAIL_NOTIFICATION" \
            --region "${AWS_REGION:-us-east-1}"
        
        print_success "Email notification subscription created. Check your email to confirm."
    fi
}

# Main deployment function
main() {
    print_status "Starting OpenAI Compliance Backup deployment..."
    print_status "Stack name: $STACK_NAME"
    print_status "Region: ${AWS_REGION:-us-east-1}"
    
    # Pre-deployment checks
    check_aws_cli
    check_aws_credentials
    validate_parameters
    
    # Create Lambda package
    create_lambda_package
    
    # Deploy infrastructure
    deploy_stack
    
    # Update Lambda code
    update_lambda_code
    
    # Setup notifications if requested
    setup_notifications
    
    # Test deployment
    test_deployment
    
    # Show outputs
    show_outputs
    
    print_success "Deployment completed successfully!"
    print_status "The backup will run daily according to the specified schedule."
    print_status "Check CloudWatch Logs for execution details: /aws/lambda/openai-compliance-backup"
}

# Usage information
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Environment variables required:"
    echo "  OPENAI_API_KEY    - Your OpenAI API key"
    echo "  OPENAI_ORG_ID     - Your OpenAI organization ID"
    echo ""
    echo "Optional environment variables:"
    echo "  AWS_REGION        - AWS region (default: us-east-1)"
    echo "  S3_BUCKET_NAME    - S3 bucket name prefix (default: openai-compliance-backup)"
    echo "  BACKUP_SCHEDULE   - Cron expression for backup schedule (default: daily at 2 AM UTC)"
    echo "  EMAIL_NOTIFICATION - Email address for notifications"
    echo ""
    echo "Example:"
    echo "  export OPENAI_API_KEY='sk-...'"
    echo "  export OPENAI_ORG_ID='org-...'"
    echo "  export EMAIL_NOTIFICATION='admin@company.com'"
    echo "  ./deploy.sh"
}

# Parse command line arguments
case "${1:-}" in
    -h|--help|help)
        usage
        exit 0
        ;;
    "")
        main
        ;;
    *)
        print_error "Unknown option: $1"
        usage
        exit 1
        ;;
esac
