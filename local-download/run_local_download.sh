#!/bin/bash

# OpenAI Compliance API Local Download Runner
# This script helps run the local download with proper configuration

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

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_SCRIPT="$SCRIPT_DIR/download_local.py"
CONFIG_FILE="$SCRIPT_DIR/local_config.env"

# Function to check prerequisites
check_prerequisites() {
    print_status "Checking prerequisites..."
    
    # Check if Python 3 is available
    if ! command -v python3 &> /dev/null; then
        print_error "Python 3 is required but not installed"
        exit 1
    fi
    
    # Check if required Python packages are available
    python3 -c "import requests" 2>/dev/null || {
        if command -v uv &> /dev/null; then
            print_error "Python 'requests' package is required. Install with: uv pip install -r requirements_local.txt"
        else
            print_error "Python 'requests' package is required. Install with: pip install -r requirements_local.txt"
        fi
        exit 1
    }
    
    # Check if download script exists
    if [[ ! -f "$PYTHON_SCRIPT" ]]; then
        print_error "Download script not found: $PYTHON_SCRIPT"
        exit 1
    fi
    
    print_success "Prerequisites check passed"
}

# Function to show usage
show_usage() {
    echo "OpenAI Compliance API Local Download Runner"
    echo ""
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --config FILE              Use specific config file (default: local_config.env)"
    echo "  --workspace-id ID          ChatGPT Enterprise workspace ID"
    echo "  --api-key KEY              OpenAI API key with compliance permissions"
    echo "  --output-dir DIR           Output directory (default: ./local_downloads)"
    echo "  --since-timestamp TS       Download conversations since Unix timestamp"
    echo "  --users USER1,USER2        Download specific users only (comma-separated)"
    echo "  --no-resume               Don't resume from previous download"
    echo "  --debug                   Enable debug logging"
    echo "  --dry-run                 Show what would be downloaded without downloading"
    echo "  -h, --help                Show this help message"
    echo ""
    echo "Environment Setup:"
    echo "  1. Copy local_config.env to local_config.env.local"
    echo "  2. Edit local_config.env.local with your credentials"
    echo "  3. Run: $0"
    echo ""
    echo "Examples:"
    echo "  # Download all conversations using config file"
    echo "  $0"
    echo ""
    echo "  # Download with custom parameters"
    echo "  $0 --workspace-id ws-123 --api-key sk-... --output-dir /path/to/downloads"
    echo ""
    echo "  # Download conversations since January 1, 2024"
    echo "  $0 --since-timestamp 1704067200"
    echo ""
    echo "  # Download specific users only"
    echo "  $0 --users user-123,user-456"
    echo ""
    echo "  # Resume previous download"
    echo "  $0  # (default behavior)"
    echo ""
    echo "  # Fresh download (don't resume)"
    echo "  $0 --no-resume"
}

# Function to validate configuration
validate_config() {
    local api_key="$1"
    local workspace_id="$2"
    
    if [[ -z "$api_key" ]]; then
        print_error "API key is required"
        echo "Set OPENAI_API_KEY in config file or use --api-key parameter"
        return 1
    fi
    
    if [[ -z "$workspace_id" ]]; then
        print_error "Workspace ID is required"
        echo "Set WORKSPACE_ID in config file or use --workspace-id parameter"
        return 1
    fi
    
    # Basic API key format validation
    if [[ ! "$api_key" =~ ^sk-[A-Za-z0-9_-]{20,}$ ]]; then
        print_warning "API key format may be invalid (expected: sk-...)"
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            return 1
        fi
    fi
    
    return 0
}

# Function to show download summary
show_download_summary() {
    local output_dir="$1"
    
    if [[ ! -d "$output_dir" ]]; then
        print_warning "Output directory not found: $output_dir"
        return
    fi
    
    print_status "Download Summary:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Count users
    local user_count=$(find "$output_dir" -maxdepth 1 -type d ! -name "_daily_summaries" ! -name ".*" ! -path "$output_dir" | wc -l)
    echo -e "${BLUE}Total Users:${NC} $user_count"
    
    # Count conversation files
    local conv_files=$(find "$output_dir" -name "conversations.json" | wc -l)
    echo -e "${BLUE}Total Days with Data:${NC} $conv_files"
    
    # Count total conversations (from JSON files)
    local total_conversations=0
    if command -v jq &> /dev/null; then
        while IFS= read -r -d '' file; do
            local count=$(jq -r '.conversation_count // 0' "$file" 2>/dev/null || echo 0)
            total_conversations=$((total_conversations + count))
        done < <(find "$output_dir" -name "conversations.json" -print0)
        echo -e "${BLUE}Total Conversations:${NC} $total_conversations"
    fi
    
    # Show directory structure sample
    echo -e "${BLUE}Directory Structure:${NC}"
    if [[ -d "$output_dir" ]]; then
        tree "$output_dir" -L 4 -d 2>/dev/null || {
            find "$output_dir" -type d | head -10 | sed 's/^/  /'
        }
    fi
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${BLUE}Data Location:${NC} $output_dir"
    echo -e "${BLUE}Logs:${NC} compliance_download.log"
}

# Function to run the download
run_download() {
    local python_args=()
    
    # Parse arguments and build Python command
    while [[ $# -gt 0 ]]; do
        case $1 in
            --config)
                CONFIG_FILE="$2"
                python_args+=(--config "$2")
                shift 2
                ;;
            --workspace-id)
                python_args+=(--workspace-id "$2")
                shift 2
                ;;
            --api-key)
                python_args+=(--api-key "$2")
                shift 2
                ;;
            --output-dir)
                python_args+=(--output-dir "$2")
                shift 2
                ;;
            --since-timestamp)
                python_args+=(--since-timestamp "$2")
                shift 2
                ;;
            --users)
                # Convert comma-separated to space-separated
                IFS=',' read -ra USERS <<< "$2"
                python_args+=(--users "${USERS[@]}")
                shift 2
                ;;
            --no-resume)
                python_args+=(--no-resume)
                shift
                ;;
            --debug)
                python_args+=(--debug)
                shift
                ;;
            --dry-run)
                print_status "Dry run mode - showing configuration without downloading"
                python_args+=(--debug)
                DRY_RUN=true
                shift
                ;;
            *)
                print_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
    
    # Load config file if it exists and no direct args provided
    if [[ -f "$CONFIG_FILE" ]] && [[ ${#python_args[@]} -eq 0 || " ${python_args[*]} " =~ " --config " ]]; then
        print_status "Loading configuration from: $CONFIG_FILE"
        source "$CONFIG_FILE"
        
        # Add config file to python args if not already there
        if [[ ! " ${python_args[*]} " =~ " --config " ]]; then
            python_args+=(--config "$CONFIG_FILE")
        fi
    elif [[ ! -f "$CONFIG_FILE" ]] && [[ ${#python_args[@]} -eq 0 ]]; then
        print_error "Configuration file not found: $CONFIG_FILE"
        print_status "Create one from the template:"
        echo "  cp local_config.env local_config.env.local"
        echo "  # Edit local_config.env.local with your credentials"
        echo "  $0"
        exit 1
    fi
    
    # Validate configuration
    local api_key="${OPENAI_API_KEY:-}"
    local workspace_id="${WORKSPACE_ID:-}"
    
    # Extract from python args if provided
    for ((i=0; i<${#python_args[@]}; i++)); do
        if [[ "${python_args[$i]}" == "--api-key" ]]; then
            api_key="${python_args[$((i+1))]}"
        elif [[ "${python_args[$i]}" == "--workspace-id" ]]; then
            workspace_id="${python_args[$((i+1))]}"
        fi
    done
    
    if ! validate_config "$api_key" "$workspace_id"; then
        exit 1
    fi
    
    # Show configuration summary
    local output_dir="${OUTPUT_DIR:-./local_downloads}"
    for ((i=0; i<${#python_args[@]}; i++)); do
        if [[ "${python_args[$i]}" == "--output-dir" ]]; then
            output_dir="${python_args[$((i+1))]}"
            break
        fi
    done
    
    print_status "Starting download with configuration:"
    echo -e "${BLUE}  Workspace ID:${NC} $workspace_id"
    echo -e "${BLUE}  Output Directory:${NC} $output_dir"
    echo -e "${BLUE}  Config File:${NC} $CONFIG_FILE"
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        print_status "Dry run completed. Configuration looks good!"
        return 0
    fi
    
    # Run the Python script
    print_status "Starting download process..."
    python3 "$PYTHON_SCRIPT" "${python_args[@]}"
    
    local exit_code=$?
    
    if [[ $exit_code -eq 0 ]]; then
        print_success "Download completed successfully!"
        show_download_summary "$output_dir"
    else
        print_error "Download failed with exit code: $exit_code"
        print_status "Check compliance_download.log for details"
    fi
    
    return $exit_code
}

# Main execution
main() {
    echo -e "${GREEN}OpenAI Compliance API Local Downloader${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Handle help
    if [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]] || [[ "$1" == "help" ]]; then
        show_usage
        exit 0
    fi
    
    # Check prerequisites
    check_prerequisites
    
    # Run download
    run_download "$@"
}

# Execute main function with all arguments
main "$@"
