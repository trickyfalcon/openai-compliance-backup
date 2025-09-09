#!/bin/bash

# OpenAI Compliance Backup Management Script
# This script provides utilities for managing the backup system

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
STACK_NAME="openai-compliance-backup-stack"
REGION="${AWS_REGION:-us-east-1}"

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

# Function to check if stack exists
check_stack_exists() {
    if aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" &>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Function to get stack outputs
get_stack_outputs() {
    if check_stack_exists; then
        aws cloudformation describe-stacks \
            --stack-name "$STACK_NAME" \
            --region "$REGION" \
            --query 'Stacks[0].Outputs' \
            --output table
    else
        print_error "Stack '$STACK_NAME' not found"
        exit 1
    fi
}

# Function to get Lambda function name
get_lambda_function_name() {
    if check_stack_exists; then
        aws cloudformation describe-stacks \
            --stack-name "$STACK_NAME" \
            --region "$REGION" \
            --query 'Stacks[0].Outputs[?OutputKey==`LambdaFunctionName`].OutputValue' \
            --output text
    else
        echo ""
    fi
}

# Function to get S3 bucket name
get_s3_bucket_name() {
    if check_stack_exists; then
        aws cloudformation describe-stacks \
            --stack-name "$STACK_NAME" \
            --region "$REGION" \
            --query 'Stacks[0].Outputs[?OutputKey==`S3BucketName`].OutputValue' \
            --output text
    else
        echo ""
    fi
}

# Function to show status
show_status() {
    print_status "Checking deployment status..."
    
    if ! check_stack_exists; then
        print_warning "Stack '$STACK_NAME' not found. Run './deploy.sh' to deploy."
        return 1
    fi
    
    local stack_status=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query 'Stacks[0].StackStatus' \
        --output text)
    
    echo -e "${BLUE}Stack Status:${NC} $stack_status"
    
    local function_name=$(get_lambda_function_name)
    if [[ -n "$function_name" ]]; then
        local last_modified=$(aws lambda get-function \
            --function-name "$function_name" \
            --region "$REGION" \
            --query 'Configuration.LastModified' \
            --output text)
        
        echo -e "${BLUE}Lambda Function:${NC} $function_name"
        echo -e "${BLUE}Last Modified:${NC} $last_modified"
    fi
    
    local bucket_name=$(get_s3_bucket_name)
    if [[ -n "$bucket_name" ]]; then
        echo -e "${BLUE}S3 Bucket:${NC} $bucket_name"
        
        local object_count=$(aws s3 ls "s3://$bucket_name/" --recursive --summarize 2>/dev/null | grep "Total Objects:" | awk '{print $3}' || echo "0")
        echo -e "${BLUE}Objects in Bucket:${NC} $object_count"
    fi
    
    print_success "Deployment is active"
}

# Function to run manual backup
run_manual_backup() {
    local date=${1:-}
    
    local function_name=$(get_lambda_function_name)
    if [[ -z "$function_name" ]]; then
        print_error "Lambda function not found. Deploy first."
        exit 1
    fi
    
    print_status "Running manual backup..."
    if [[ -n "$date" ]]; then
        print_status "Date: $date"
        local payload="{\"date\": \"$date\"}"
    else
        print_status "Date: Previous day (default)"
        local payload="{}"
    fi
    
    local temp_file=$(mktemp)
    
    aws lambda invoke \
        --function-name "$function_name" \
        --region "$REGION" \
        --payload "$payload" \
        "$temp_file"
    
    if [[ $? -eq 0 ]]; then
        print_success "Backup completed"
        echo "Response:"
        cat "$temp_file" | jq '.' 2>/dev/null || cat "$temp_file"
        rm -f "$temp_file"
    else
        print_error "Backup failed"
        rm -f "$temp_file"
        exit 1
    fi
}

# Function to view logs
view_logs() {
    local function_name=$(get_lambda_function_name)
    if [[ -z "$function_name" ]]; then
        print_error "Lambda function not found. Deploy first."
        exit 1
    fi
    
    local log_group="/aws/lambda/$function_name"
    local hours=${1:-24}
    
    print_status "Viewing logs from the last $hours hours..."
    
    aws logs filter-log-events \
        --log-group-name "$log_group" \
        --region "$REGION" \
        --start-time $(($(date +%s) - hours * 3600))000 \
        --query 'events[*].[timestamp,message]' \
        --output table
}

# Function to follow logs in real-time
follow_logs() {
    local function_name=$(get_lambda_function_name)
    if [[ -z "$function_name" ]]; then
        print_error "Lambda function not found. Deploy first."
        exit 1
    fi
    
    local log_group="/aws/lambda/$function_name"
    
    print_status "Following logs in real-time (Ctrl+C to stop)..."
    aws logs tail "$log_group" --region "$REGION" --follow
}

# Function to list backups
list_backups() {
    local bucket_name=$(get_s3_bucket_name)
    if [[ -z "$bucket_name" ]]; then
        print_error "S3 bucket not found. Deploy first."
        exit 1
    fi
    
    local user_filter=${1:-}
    local date_filter=${2:-}
    
    print_status "Listing backups in S3 bucket: $bucket_name"
    
    local prefix=""
    if [[ -n "$user_filter" && -n "$date_filter" ]]; then
        # Convert date format YYYY-MM-DD to YYYY/MM/DD
        local date_path=$(echo "$date_filter" | sed 's/-/\//g')
        prefix="$user_filter/$date_path/"
        print_status "Filter: User=$user_filter, Date=$date_filter"
    elif [[ -n "$user_filter" ]]; then
        prefix="$user_filter/"
        print_status "Filter: User=$user_filter"
    fi
    
    aws s3 ls "s3://$bucket_name/$prefix" --recursive --human-readable --summarize
}

# Function to download backup
download_backup() {
    local user_id=${1:-}
    local date=${2:-}
    local output_dir=${3:-./downloads}
    
    if [[ -z "$user_id" || -z "$date" ]]; then
        print_error "Usage: $0 download <user_id> <date> [output_dir]"
        echo "Example: $0 download user123 2024-01-15"
        exit 1
    fi
    
    local bucket_name=$(get_s3_bucket_name)
    if [[ -z "$bucket_name" ]]; then
        print_error "S3 bucket not found. Deploy first."
        exit 1
    fi
    
    # Convert date format YYYY-MM-DD to YYYY/MM/DD
    local date_path=$(echo "$date" | sed 's/-/\//g')
    local s3_key="$user_id/$date_path/conversations.json"
    
    print_status "Downloading backup for user '$user_id' on date '$date'..."
    
    mkdir -p "$output_dir"
    local local_file="$output_dir/${user_id}_${date}_conversations.json"
    
    aws s3 cp "s3://$bucket_name/$s3_key" "$local_file" --region "$REGION"
    
    if [[ $? -eq 0 ]]; then
        print_success "Downloaded to: $local_file"
    else
        print_error "Download failed"
        exit 1
    fi
}

# Function to show usage statistics
show_stats() {
    local bucket_name=$(get_s3_bucket_name)
    if [[ -z "$bucket_name" ]]; then
        print_error "S3 bucket not found. Deploy first."
        exit 1
    fi
    
    print_status "Generating usage statistics..."
    
    # Get total objects and size
    local summary=$(aws s3 ls "s3://$bucket_name/" --recursive --summarize)
    local total_objects=$(echo "$summary" | grep "Total Objects:" | awk '{print $3}')
    local total_size=$(echo "$summary" | grep "Total Size:" | awk '{print $3}')
    
    echo -e "${BLUE}Total Objects:${NC} $total_objects"
    echo -e "${BLUE}Total Size:${NC} $total_size bytes"
    
    # Count users
    local users=$(aws s3 ls "s3://$bucket_name/" | grep -v "_daily_summaries" | wc -l)
    echo -e "${BLUE}Users with Backups:${NC} $users"
    
    # Recent backup dates
    print_status "Recent backup dates:"
    aws s3 ls "s3://$bucket_name/_daily_summaries/" --recursive | tail -5
}

# Function to delete stack
delete_stack() {
    if ! check_stack_exists; then
        print_warning "Stack '$STACK_NAME' not found."
        return 0
    fi
    
    echo -e "${RED}WARNING: This will delete all AWS resources and the S3 bucket!${NC}"
    echo -e "${RED}All backup data will be permanently lost!${NC}"
    echo -n -e "${YELLOW}Are you sure? Type 'DELETE' to confirm: ${NC}"
    read confirmation
    
    if [[ "$confirmation" != "DELETE" ]]; then
        print_status "Deletion cancelled"
        return 0
    fi
    
    print_status "Deleting CloudFormation stack..."
    
    # First, empty the S3 bucket
    local bucket_name=$(get_s3_bucket_name)
    if [[ -n "$bucket_name" ]]; then
        print_status "Emptying S3 bucket: $bucket_name"
        aws s3 rm "s3://$bucket_name/" --recursive --region "$REGION"
    fi
    
    aws cloudformation delete-stack \
        --stack-name "$STACK_NAME" \
        --region "$REGION"
    
    print_status "Waiting for stack deletion to complete..."
    aws cloudformation wait stack-delete-complete \
        --stack-name "$STACK_NAME" \
        --region "$REGION"
    
    print_success "Stack deleted successfully"
}

# Function to show help
show_help() {
    echo "OpenAI Compliance Backup Management Tool"
    echo ""
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  status                     Show deployment status"
    echo "  outputs                    Show CloudFormation stack outputs"
    echo "  backup [date]              Run manual backup (optional: YYYY-MM-DD)"
    echo "  logs [hours]               View logs from last N hours (default: 24)"
    echo "  follow-logs               Follow logs in real-time"
    echo "  list [user] [date]        List backups (optional filters)"
    echo "  download <user> <date>    Download specific backup"
    echo "  stats                     Show usage statistics"
    echo "  delete                    Delete entire deployment (DESTRUCTIVE)"
    echo ""
    echo "Examples:"
    echo "  $0 status                              # Show current status"
    echo "  $0 backup 2024-01-15                  # Backup specific date"
    echo "  $0 logs 48                             # View logs from last 48 hours"
    echo "  $0 list user123                       # List backups for user123"
    echo "  $0 list user123 2024-01-15            # List specific user/date"
    echo "  $0 download user123 2024-01-15        # Download specific backup"
    echo ""
    echo "Environment variables:"
    echo "  AWS_REGION                Region (default: us-east-1)"
    echo "  STACK_NAME                Stack name (default: openai-compliance-backup-stack)"
}

# Main command dispatcher
main() {
    local command=${1:-help}
    
    case "$command" in
        status)
            show_status
            ;;
        outputs)
            get_stack_outputs
            ;;
        backup)
            run_manual_backup "$2"
            ;;
        logs)
            view_logs "$2"
            ;;
        follow-logs)
            follow_logs
            ;;
        list)
            list_backups "$2" "$3"
            ;;
        download)
            download_backup "$2" "$3" "$4"
            ;;
        stats)
            show_stats
            ;;
        delete)
            delete_stack
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            print_error "Unknown command: $command"
            show_help
            exit 1
            ;;
    esac
}

# Check for AWS CLI
if ! command -v aws &> /dev/null; then
    print_error "AWS CLI is required but not installed"
    exit 1
fi

# Check for jq (optional but recommended)
if ! command -v jq &> /dev/null; then
    print_warning "jq not installed - JSON output may be less readable"
fi

# Run main function
main "$@"
