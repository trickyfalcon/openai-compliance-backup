#!/bin/bash

# Environment Setup Script for OpenAI Compliance Backup
# This script helps set up the required environment variables

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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


# Function to validate OpenAI API key format
validate_openai_key() {
    local key=$1
    if [[ ! "$key" =~ ^sk-[A-Za-z0-9_-]{20,}$ ]]; then
        print_warning "OpenAI API key format may be invalid. Expected format: sk-..."
        echo -n -e "${YELLOW}Continue anyway? (y/N):${NC} "
        read -r confirm </dev/tty
        echo
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            return 1
        fi
    fi
    return 0
}

# Function to validate workspace ID
validate_workspace_id() {
    local workspace_id=$1
    if [[ -z "$workspace_id" ]]; then
        print_error "Workspace ID cannot be empty"
        return 1
    fi
    
    # Basic validation - workspace IDs can have various formats
    if [[ ${#workspace_id} -lt 5 ]]; then
        print_warning "Workspace ID seems too short. Please verify it's correct."
        echo -n -e "${YELLOW}Continue anyway? (y/N):${NC} "
        read -r confirm </dev/tty
        echo
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            return 1
        fi
    fi
    return 0
}

# Function to create .env file
create_env_file() {
    local env_file=".env"
    
    print_status "Creating environment configuration file: $env_file"
    
    cat > "$env_file" << EOF
# OpenAI Compliance Backup Configuration
# Generated on $(date)

# Required: OpenAI API credentials
export OPENAI_API_KEY="$OPENAI_API_KEY"
export WORKSPACE_ID="$WORKSPACE_ID"

# Optional: AWS configuration
export AWS_REGION="${AWS_REGION:-us-east-1}"
export S3_BUCKET_NAME="${S3_BUCKET_NAME:-openai-compliance-backup}"

# Optional: Backup schedule (cron expression)
export BACKUP_SCHEDULE="${BACKUP_SCHEDULE:-cron(0 2 * * ? *)}"

# Optional: Notification email
export EMAIL_NOTIFICATION="${EMAIL_NOTIFICATION:-}"

# Usage: source .env before running deployment
# Example: source .env && ./deploy.sh
EOF

    print_success "Environment file created: $env_file"
    print_status "To use these settings, run: source .env"
}

# Function to test AWS credentials
test_aws_credentials() {
    print_status "Testing AWS credentials..."
    
    if ! command -v aws &> /dev/null; then
        print_warning "AWS CLI not found. Please install it first:"
        echo "  - macOS: brew install awscli"
        echo "  - Linux: pip install awscli"
        echo "  - Windows: Download from https://aws.amazon.com/cli/"
        return 1
    fi
    
    if aws sts get-caller-identity &> /dev/null; then
        local account_id=$(aws sts get-caller-identity --query 'Account' --output text)
        local user_arn=$(aws sts get-caller-identity --query 'Arn' --output text)
        print_success "AWS credentials valid"
        print_status "Account ID: $account_id"
        print_status "User/Role: $user_arn"
        return 0
    else
        print_error "AWS credentials not configured or invalid"
        print_status "Run 'aws configure' to set up your credentials"
        return 1
    fi
}

# Function to display setup summary
display_summary() {
    echo
    print_status "Setup Summary:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${BLUE}OpenAI API Key:${NC} ${OPENAI_API_KEY:0:10}..."
    echo -e "${BLUE}Workspace ID:${NC} $WORKSPACE_ID"
    echo -e "${BLUE}AWS Region:${NC} ${AWS_REGION:-us-east-1}"
    echo -e "${BLUE}S3 Bucket Prefix:${NC} ${S3_BUCKET_NAME:-openai-compliance-backup}"
    echo -e "${BLUE}Backup Schedule:${NC} ${BACKUP_SCHEDULE:-cron(0 2 * * ? *)}"
    if [[ -n "$EMAIL_NOTIFICATION" ]]; then
        echo -e "${BLUE}Notification Email:${NC} $EMAIL_NOTIFICATION"
    fi
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    print_status "Next steps:"
    echo "1. Review the settings above"
    echo "2. Run: source .env"
    echo "3. Run: ./deploy.sh"
    echo
}

# Main setup function
main() {
    echo -e "${GREEN}OpenAI Compliance Backup - Environment Setup${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    
    # Collect OpenAI credentials
    print_status "Setting up OpenAI API credentials..."
    echo
    
    while true; do
        echo -n -e "${BLUE}Enter your OpenAI API key (starts with sk-):${NC} "
        read -s -r OPENAI_API_KEY
        echo
        if validate_openai_key "$OPENAI_API_KEY"; then
            break
        fi
    done
    
    while true; do
        echo -n -e "${BLUE}Enter your ChatGPT Enterprise Workspace ID:${NC} "
        read -r WORKSPACE_ID
        if validate_workspace_id "$WORKSPACE_ID"; then
            break
        fi
    done
    
    echo
    
    # Collect optional AWS settings
    print_status "Setting up AWS configuration (optional - press Enter for defaults)..."
    echo
    
    echo -n -e "${BLUE}AWS Region (default: us-east-1):${NC} "
    read -r aws_region </dev/tty
    AWS_REGION="${aws_region:-us-east-1}"
    
    echo -n -e "${BLUE}S3 Bucket Name Prefix (default: openai-compliance-backup):${NC} "
    read -r bucket_name </dev/tty
    S3_BUCKET_NAME="${bucket_name:-openai-compliance-backup}"
    
    echo -n -e "${BLUE}Backup Schedule - Cron Expression (default: daily at 2 AM UTC):${NC} "
    read -r schedule </dev/tty
    BACKUP_SCHEDULE="${schedule:-cron(0 2 * * ? *)}"
    
    echo -n -e "${BLUE}Email for notifications (optional):${NC} "
    read -r email </dev/tty
    EMAIL_NOTIFICATION="$email"
    
    echo
    
    # Test AWS credentials
    test_aws_credentials
    
    echo
    
    # Create .env file
    create_env_file
    
    # Display summary
    display_summary
}

# Usage information
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "This script helps you set up the environment variables required"
    echo "for the OpenAI Compliance Backup deployment."
    echo ""
    echo "Options:"
    echo "  -h, --help    Show this help message"
    echo ""
    echo "The script will prompt you for:"
    echo "  - OpenAI API key"
    echo "  - OpenAI Organization ID"
    echo "  - AWS region (optional)"
    echo "  - S3 bucket name prefix (optional)"
    echo "  - Backup schedule (optional)"
    echo "  - Email for notifications (optional)"
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
