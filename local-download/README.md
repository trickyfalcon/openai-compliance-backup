# Local Download for OpenAI Compliance Data

This folder contains tools to download OpenAI compliance data directly to your local machine with **smart incremental downloading** for efficient data collection.

## 🧠 Smart Incremental Downloads

The local downloader automatically handles efficient data collection:
- **First run**: Bulk downloads from **July 2nd, 2025** to today
- **Subsequent runs**: Only downloads NEW conversations since last run  
- **State tracking**: Maintains last processed timestamp in `.download_state.json`
- **Configurable**: Enable/disable smart behavior via configuration
- **Future-proof**: Uses Python 3.12 for long-term compatibility

## 🚀 Quick Start

1. **Install Dependencies**:
   ```bash
   # Install uv if you don't have it (much faster than pip)
   curl -LsSf https://astral.sh/uv/install.sh | sh
   
   # Install Python dependencies
   uv pip install -r requirements_local.txt
   ```

2. **Configure Credentials**:
   ```bash
   cp local_config.env local_config.env.local
   # Edit local_config.env.local with your API key and workspace ID
   ```

3. **Download All Conversations**:
   ```bash
   ./run_local_download.sh --config local_config.env.local
   ```

## 📁 Files

| File | Description |
|------|-------------|
| `download_local.py` | Core Python script that downloads conversations from OpenAI Compliance API |
| `run_local_download.sh` | Bash wrapper with advanced options and validation |
| `local_config.env` | Configuration template for API credentials and settings |
| `requirements_local.txt` | Python dependencies (only `requests` needed) |

## ⚙️ Usage Options

### Basic Usage
```bash
# Download all conversations
./run_local_download.sh

# Download with custom config file
./run_local_download.sh --config my_config.env

# Download with direct parameters (no config file)
./run_local_download.sh --workspace-id ws-123 --api-key sk-...
```

### Advanced Usage
```bash
# Download conversations since January 1, 2024
./run_local_download.sh --since-timestamp 1704067200

# Download specific users only
./run_local_download.sh --users user-123,user-456,user-789

# Custom output directory
./run_local_download.sh --output-dir /path/to/backups

# Enable debug logging
./run_local_download.sh --debug

# Fresh download (don't resume from previous)
./run_local_download.sh --no-resume

# Disable smart incremental (always start from July 2, 2025)
./run_local_download.sh --no-smart-incremental

# Test configuration without downloading
./run_local_download.sh --dry-run
```

## 📊 Data Organization

Downloads are organized locally with the same structure as the AWS version:
```
local_downloads/
├── user1/
│   └── 2024/01/15/conversations.json
├── user2/
│   └── 2024/01/15/conversations.json  
├── _daily_summaries/
│   └── 2024/01/15/summary.json
└── .download_state.json              # Smart incremental state tracking
```

### State Files
- **`.download_state.json`**: Tracks last processed timestamp for smart incremental downloads
- **`.download_progress.json`**: Temporary pagination state (auto-cleaned after completion)
- **`compliance_download.log`**: Detailed execution logs

Each conversation file contains:
```json
{
  "date": "2024-01-15",
  "user_id": "user123",
  "conversation_count": 5,
  "conversations": [...],
  "metadata": {
    "download_timestamp": "2024-01-16T10:30:00Z",
    "source": "local_compliance_downloader"
  }
}
```

## 🔐 Configuration

Edit `local_config.env.local` with your settings:

```bash
# Required
export OPENAI_API_KEY="sk-your-api-key-here"
export WORKSPACE_ID="your-workspace-id-here"

# Optional
export OUTPUT_DIR="./custom_downloads"
export SINCE_TIMESTAMP="1704067200"  # Download since specific date
export SPECIFIC_USERS="user1,user2"  # Download specific users only
export RATE_LIMIT_DELAY="1.2"        # Delay between API calls (seconds)
export DEBUG="true"                   # Enable debug logging
```

## 🔑 API Key Setup

1. Get API key from [OpenAI Platform](https://platform.openai.com/api-keys)
   - Must select correct Organization (your Enterprise workspace)
   - Create with "Default Project | All Permissions"
   
2. Email `support@openai.com` with:
   - Last 4 digits of API key
   - Key name
   - Created by name
   - Requested scope: `read`

3. OpenAI will grant Compliance API access

4. **Important**: Use base URL `https://api.chatgpt.com/v1` (NOT api.openai.com!)

## 🚀 Features

- ✅ **Pagination**: Downloads all conversations regardless of dataset size
- ✅ **Rate Limiting**: Respects API limits (50 requests/minute)
- ✅ **Resume Capability**: Continue interrupted downloads where you left off
- ✅ **Error Handling**: Comprehensive retry logic with exponential backoff
- ✅ **Flexible Filtering**: Download by date range, specific users, etc.
- ✅ **Progress Tracking**: Real-time progress reporting
- ✅ **Logging**: Detailed logs saved to `compliance_download.log`

## 🛠️ Troubleshooting

### Common Issues

1. **"Authentication failed (401)"**
   - Check API key format (should start with `sk-`)
   - Ensure compliance_export permissions granted by OpenAI

2. **"Resource not found (404)"**
   - Verify workspace ID is correct
   - Check API base URL is `https://api.chatgpt.com/v1`

3. **"Rate limited (429)"**
   - Script automatically handles this with backoff
   - Reduce `RATE_LIMIT_DELAY` if needed

4. **"ModuleNotFoundError: requests"**
   - Install dependencies: `uv pip install -r requirements_local.txt`
   - Or with pip: `pip install -r requirements_local.txt`

5. **Large dataset timeouts**
   - Use `--users` to download specific users
   - Use `--since-timestamp` for date filtering
   - Script supports resume on interruption

### Debug Mode

Enable detailed logging:
```bash
./run_local_download.sh --debug
```

Check logs:
```bash
tail -f compliance_download.log
```

## 📈 Performance Tips

- **Large datasets**: Use filtering options (`--users`, `--since-timestamp`)
- **Network issues**: Script automatically retries with backoff
- **Interruptions**: Use Ctrl+C to stop gracefully, then resume later
- **Rate limits**: Default 1.2s delay between requests (50/min limit)

## 🆚 vs AWS Lambda Deployment

| Feature | Local Download | AWS Lambda |
|---------|----------------|------------|
| Setup Time | 5 minutes | 15 minutes |
| Cost | Free | AWS charges |
| Automation | Manual/cron | Fully automated |
| Storage | Local files | S3 (redundant) |
| Monitoring | Logs only | CloudWatch + SNS |
| Best For | Ad-hoc exports | Production backups |
