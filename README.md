# OpenAI Compliance API Daily Backup

This application automatically backs up OpenAI compliance data daily using AWS Lambda and stores the organized results in Amazon S3. The system is designed for enterprise customers with access to OpenAI's Compliance API.

## 🏗️ Architecture

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────────┐
│   EventBridge   │───▶│  Lambda Function │───▶│        S3 Bucket    │
│  (Daily Timer)  │    │  (Python 3.9)   │    │ (Organized by User) │
└─────────────────┘    └──────────────────┘    └─────────────────────┘
                                │
                                ▼
                       ┌──────────────────┐
                       │ OpenAI API       │
                       │ (Compliance)     │
                       └──────────────────┘
```

## 📁 File Organization in S3

The system organizes data in S3 with the following structure:

```
s3://your-bucket-name/
├── user1/
│   ├── 2024/
│   │   ├── 01/
│   │   │   ├── 15/
│   │   │   │   └── conversations.json
│   │   │   └── 16/
│   │   │       └── conversations.json
│   │   └── 02/
│   │       └── 01/
│   │           └── conversations.json
│   └── ...
├── user2/
│   └── 2024/
│       └── ...
└── _daily_summaries/
    └── 2024/
        ├── 01/
        │   ├── 15/
        │   │   └── summary.json
        │   └── 16/
        │       └── summary.json
        └── 02/
            └── 01/
                └── summary.json
```

## 📂 Project Structure

The project is organized into two main components:

```
openaichatbackup/
├── aws-lambda/                    # AWS Lambda Deployment
│   ├── lambda_function.py             # Core Lambda function (8.3KB)
│   ├── cloudformation-template.yaml   # AWS infrastructure (7.1KB)
│   ├── requirements.txt              # Lambda dependencies
│   ├── config.json                  # Configuration settings
│   ├── setup-env.sh                 # Interactive environment setup (7.7KB)
│   ├── deploy.sh                    # Automated deployment (7.3KB)
│   └── manage.sh                    # Management utilities (12KB)
├── local-download/                # Local Download Option
│   ├── download_local.py             # Local download script (21.5KB)
│   ├── run_local_download.sh         # Local download runner (10.7KB)
│   ├── local_config.env             # Local configuration template
│   └── requirements_local.txt       # Local dependencies
├── README.md                      # Complete documentation
└── openai.json                    # OpenAI API specification (158KB)
```

## 🚀 Quick Start

You can use this application in two ways:
1. **AWS Lambda Deployment** - Automated daily backups stored in S3
2. **Local Download Script** - Run locally to download conversations on-demand

## 🧠 Smart Date Range Processing

Both deployment options now include intelligent date range management:

### **🔄 Initial Bulk Load**
- **First run**: Downloads all conversations from **July 2nd, 2025** to today
- Handles large datasets efficiently with pagination and rate limiting
- Creates complete historical backup in organized structure

### **📈 Daily Incremental Updates**
- **Subsequent runs**: Only downloads NEW conversations since last successful run
- Tracks state automatically (S3 for Lambda, local file for downloads)
- Minimizes API calls and processing time
- Ensures no data is missed or duplicated

### **⚙️ Configurable Behavior**
- **Smart mode** (default): Automatic bulk + incremental as described above
- **Manual override**: Specify custom date ranges via timestamp parameters
- **Legacy mode**: Disable smart behavior to always pull from July 2nd, 2025

### Prerequisites

- OpenAI Enterprise account with Compliance API access
- For AWS deployment: AWS CLI installed and configured
- Python 3.12+ (for local development/downloads)
- For local downloads: `uv` package manager (recommended) or `pip`
- Bash shell (Linux/macOS/WSL)

### Option 1: Local Download (Quick Start)

For immediate downloading of conversations to your local machine:

1. **Install Dependencies**:
   ```bash
   # Install uv if you don't have it (much faster than pip)
   curl -LsSf https://astral.sh/uv/install.sh | sh
   
   # Install Python dependencies
   uv pip install -r local-download/requirements_local.txt
   ```

2. **Configure Credentials**:
   ```bash
   cp local-download/local_config.env local-download/local_config.env.local
   # Edit local-download/local_config.env.local with your API key and workspace ID
   ```

3. **Download All Conversations**:
   ```bash
   ./local-download/run_local_download.sh --config local-download/local_config.env.local
   ```

The local download will organize conversations in `./local_downloads/` using the same structure:
```
local_downloads/
├── user1/2024/01/15/conversations.json
├── user2/2024/01/15/conversations.json  
└── _daily_summaries/2024/01/15/summary.json
```

### Option 2: AWS Lambda Deployment (Automated)

For automated daily backups stored in AWS S3:

1. **Environment Setup**

   Run the interactive setup script:

   ```bash
   ./aws-lambda/setup-env.sh
   ```

   This will prompt you for:
   - OpenAI API key (starts with `sk-`)
   - OpenAI Organization ID (starts with `org-`)
   - AWS region (default: `us-east-1`)
   - S3 bucket name prefix
   - Backup schedule (cron expression)
   - Email for notifications (optional)

2. **Deploy to AWS**

   Load environment variables and deploy:

   ```bash
   source .env
   ./aws-lambda/deploy.sh
   ```

   The deployment script will:
   - Create Lambda deployment package
   - Deploy CloudFormation stack
   - Set up all AWS resources
   - Test the deployment
   - Display stack outputs

3. **Verify Deployment**

   Check the Lambda function logs:

   ```bash
   aws logs tail /aws/lambda/openai-compliance-backup --follow
   ```

## 📋 Manual Configuration

If you prefer to set up environment variables manually:

```bash
# Required
export OPENAI_API_KEY="sk-your-api-key"
export OPENAI_ORG_ID="org-your-org-id"

# Optional
export AWS_REGION="us-east-1"
export S3_BUCKET_NAME="openai-compliance-backup"
export BACKUP_SCHEDULE="cron(0 2 * * ? *)"  # Daily at 2 AM UTC
export EMAIL_NOTIFICATION="admin@company.com"
```

## 🏭 AWS Resources Created

The CloudFormation template creates:

### Core Resources
- **Lambda Function**: Executes the backup logic
- **S3 Bucket**: Stores conversation data with encryption
- **IAM Role**: Provides necessary permissions
- **EventBridge Rule**: Triggers daily backups

### Monitoring & Alerts
- **CloudWatch Log Group**: Stores Lambda execution logs
- **CloudWatch Alarms**: Monitor errors and performance
- **SNS Topic**: Sends notifications on failures

### Security & Compliance
- **Bucket Encryption**: AES-256 encryption at rest
- **Versioning**: Enabled for data protection
- **Lifecycle Policies**: Automatic transition to cheaper storage classes
- **IAM Policies**: Least privilege access

## 📊 Data Format

### Individual Conversation File
Each `conversations.json` file contains:

```json
{
  "date": "2024-01-15",
  "user_id": "user123",
  "conversation_count": 5,
  "conversations": [
    {
      "id": "conv_123",
      "timestamp": "2024-01-15T10:30:00Z",
      "messages": [...],
      "metadata": {...}
    }
  ],
  "metadata": {
    "backup_timestamp": "2024-01-16T02:00:00Z",
    "lambda_function": "openai-compliance-backup"
  }
}
```

### Daily Summary File
Each `summary.json` file contains:

```json
{
  "date": "2024-01-15",
  "total_users": 25,
  "total_conversations": 150,
  "user_statistics": {
    "user123": {
      "conversation_count": 5,
      "total_messages": 23
    }
  },
  "backup_timestamp": "2024-01-16T02:00:00Z"
}
```

## ⚙️ Configuration

### Backup Schedule

The default schedule runs daily at 2 AM UTC. Modify using cron expressions:

- `cron(0 2 * * ? *)` - Daily at 2 AM UTC
- `cron(0 8 * * MON *)` - Weekly on Mondays at 8 AM UTC
- `cron(0 12 1 * ? *)` - Monthly on the 1st at 12 PM UTC

### Storage Classes

Automatic lifecycle transitions:
- Day 0-30: Standard storage
- Day 30-90: Standard-IA (Infrequent Access)
- Day 90+: Glacier (Archive)

### Retention

- Lambda logs: 30 days
- S3 versioning: Enabled
- Incomplete uploads: Cleaned after 7 days

## 🔍 Monitoring

### CloudWatch Dashboards

Create custom dashboards to monitor:
- Lambda execution duration
- Error rates
- S3 storage usage
- API call patterns

### Log Analysis

Search logs for specific patterns:

```bash
# View recent executions
aws logs filter-log-events \
  --log-group-name /aws/lambda/openai-compliance-backup \
  --start-time $(date -d '1 hour ago' +%s)000

# Search for errors
aws logs filter-log-events \
  --log-group-name /aws/lambda/openai-compliance-backup \
  --filter-pattern "ERROR"
```

### Alerts

The system creates alerts for:
- Lambda execution errors
- Function duration approaching timeout
- High error rates

## 🛠️ Maintenance

### Manual Backup

Trigger a backup for a specific date:

```bash
aws lambda invoke \
  --function-name openai-compliance-backup \
  --payload '{"date": "2024-01-15"}' \
  /tmp/response.json
```

### Update Lambda Code

After making changes to `lambda_function.py`:

```bash
./deploy.sh  # This will update the code automatically
```

### Scaling Considerations

For high-volume organizations:
- Increase Lambda timeout (up to 15 minutes)
- Increase memory allocation
- Consider batch processing
- Monitor API rate limits

## 🔒 Security Best Practices

1. **API Keys**: Store in AWS Systems Manager Parameter Store or AWS Secrets Manager
2. **IAM Roles**: Use least privilege principles
3. **Encryption**: Enable at rest and in transit
4. **Monitoring**: Set up comprehensive logging and alerting
5. **Access Control**: Restrict S3 bucket access to necessary services only

### Environment Variable Security

For production deployments, consider using AWS Systems Manager:

```bash
# Store API key securely
aws ssm put-parameter \
  --name "/openai-backup/api-key" \
  --value "sk-your-api-key" \
  --type "SecureString"

# Update Lambda to use SSM instead of environment variables
```

## 📚 API Reference

### OpenAI Compliance API

The application uses OpenAI's Compliance API endpoint:
- **Endpoint**: `https://api.openai.com/v1/organization/audit_logs`
- **Authentication**: Bearer token + Organization header
- **Rate Limits**: Varies by plan
- **Pagination**: Supported via `after` parameter

### Lambda Function Interface

```python
# Event structure for manual invocation
{
    "date": "2024-01-15",  # Optional: specific date to backup
    "test": true           # Optional: test mode
}

# Response structure
{
    "statusCode": 200,
    "body": {
        "message": "Backup completed successfully",
        "date": "2024-01-15",
        "total_users": 25,
        "total_conversations": 150
    }
}
```

## 🚨 Troubleshooting

### Common Issues

1. **Lambda Timeout**
   - Increase timeout in CloudFormation template
   - Monitor execution duration
   - Consider pagination for large datasets

2. **API Rate Limits**
   - Implement exponential backoff
   - Monitor OpenAI usage dashboard
   - Consider spreading requests across time

3. **S3 Access Denied**
   - Check IAM role permissions
   - Verify bucket policy
   - Ensure correct AWS region

4. **Missing Data**
   - Check Lambda execution logs
   - Verify API key permissions
   - Review OpenAI organization access

### Debug Mode

Enable verbose logging by setting environment variable:

```bash
export DEBUG=true
./deploy.sh
```

### Log Analysis Commands

```bash
# View Lambda function configuration
aws lambda get-function --function-name openai-compliance-backup

# Check recent executions
aws lambda get-function --function-name openai-compliance-backup \
  --qualifier '$LATEST'

# Monitor real-time logs
aws logs tail /aws/lambda/openai-compliance-backup --follow
```

## 💻 Local Download Usage

The local download script provides flexible options for downloading conversation data directly to your machine.

### Basic Usage

```bash
# Download all conversations
./run_local_download.sh

# Download with custom config file
./run_local_download.sh --config my_config.env

# Download with direct parameters
./run_local_download.sh --workspace-id ws-123 --api-key sk-... --output-dir /path/to/downloads
```

### Advanced Usage

```bash
# Download conversations since January 1, 2024 (Unix timestamp)
./run_local_download.sh --since-timestamp 1704067200

# Download specific users only
./run_local_download.sh --users user-123,user-456,user-789

# Download with debug logging
./run_local_download.sh --debug

# Fresh download (don't resume from previous)
./run_local_download.sh --no-resume

# Dry run (test configuration without downloading)
./run_local_download.sh --dry-run
```

### Configuration File Options

Edit `local_config.env` with your settings:

```bash
# Required
export OPENAI_API_KEY="sk-your-api-key-here"
export WORKSPACE_ID="your-workspace-id-here"

# Optional
export OUTPUT_DIR="./custom_downloads"
export SINCE_TIMESTAMP="1704067200"  # Download since specific date
export SPECIFIC_USERS="user1,user2"  # Download specific users only
export RATE_LIMIT_DELAY="1.2"        # Delay between API calls
export DEBUG="true"                   # Enable debug logging
```

### API Key Setup

1. Get API key from [OpenAI Platform](https://platform.openai.com/api-keys)
2. Email support@openai.com with:
   - Last 4 digits of API key
   - Key name
   - Created by name  
   - Requested scope: `read`
3. OpenAI will grant Compliance API access
4. Use the key with base URL: `https://api.chatgpt.com/v1` (not api.openai.com!)

### Local vs AWS Comparison

| Feature | Local Download | AWS Lambda |
|---------|----------------|------------|
| **Setup Time** | 5 minutes | 15 minutes |
| **Cost** | Free | AWS charges |
| **Automation** | Manual/cron | Fully automated |
| **Storage** | Local files | S3 (redundant) |
| **Monitoring** | Logs only | CloudWatch + SNS |
| **Resumption** | Yes | Per execution |
| **Best For** | Ad-hoc downloads | Production backups |

## 🧪 Testing

### Local Download Tests

```bash
# Test configuration without downloading
./run_local_download.sh --dry-run

# Test with small dataset (specific users)
./run_local_download.sh --users user-123 --debug

# Test resumption capability
./run_local_download.sh  # Start download
# Ctrl+C to interrupt
./run_local_download.sh  # Resume from where it left off
```

### Lambda Function Tests

```bash
# Test Lambda function locally
python lambda_function.py

# Test with sample event
echo '{"test": true}' | python -c "
import json, sys
from lambda_function import lambda_handler
event = json.load(sys.stdin)
result = lambda_handler(event, None)
print(json.dumps(result, indent=2))
"
```

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch
3. Make changes and add tests
4. Update documentation
5. Submit a pull request

## 📄 License

This project is licensed under the MIT License - see the LICENSE file for details.

## 🆘 Support

For issues and questions:
1. Check the troubleshooting section
2. Review CloudWatch logs
3. Verify API credentials and permissions
4. Contact your OpenAI enterprise support team for API-related issues

---

**⚠️ Important Notes:**
- This application is designed for OpenAI Enterprise customers with Compliance API access
- Ensure you comply with your organization's data retention and privacy policies
- Monitor costs for Lambda execution time and S3 storage
- Regularly review and rotate API keys
