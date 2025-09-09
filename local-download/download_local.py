#!/usr/bin/env python3
"""
OpenAI Compliance API Local Download Script

This script downloads all conversation data from the ChatGPT Enterprise Compliance API
and organizes it locally by user and date.

Usage:
    python download_local.py --workspace-id WORKSPACE_ID --api-key API_KEY
    python download_local.py --config config.env
    python download_local.py --help

Requirements:
    - ChatGPT Enterprise account with Compliance API access
    - API key with compliance_export read permissions
    - Workspace ID from your ChatGPT Enterprise workspace
"""

import argparse
import json
import os
import sys
import time
import requests
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Dict, List, Any, Optional
import logging
from dataclasses import dataclass
from urllib.parse import urljoin
import signal

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('compliance_download.log'),
        logging.StreamHandler(sys.stdout)
    ]
)
logger = logging.getLogger(__name__)

@dataclass
class DownloadConfig:
    """Configuration for the download process."""
    api_key: str
    workspace_id: str
    base_url: str = "https://api.chatgpt.com/v1/"
    output_dir: str = "./downloads"
    rate_limit_delay: float = 1.2  # Seconds between requests (50/min = 1.2s)
    max_retries: int = 3
    timeout: int = 30
    since_timestamp: Optional[int] = None
    specific_users: Optional[List[str]] = None
    batch_size: int = 500  # Max allowed by API
    
    # Smart date range constants
    initial_start_date: datetime = datetime(2025, 7, 2)  # July 2nd, 2025
    enable_smart_incremental: bool = True

class ComplianceDownloader:
    """Downloads conversation data from OpenAI Compliance API."""
    
    def __init__(self, config: DownloadConfig):
        self.config = config
        self.session = self._setup_session()
        self.stats = {
            'total_conversations': 0,
            'total_users': 0,
            'total_requests': 0,
            'failed_requests': 0,
            'start_time': datetime.now()
        }
        self.interrupted = False
        
        # State tracking for smart incremental downloads
        self.state_file = Path(config.output_dir) / ".download_state.json"
        
        # Setup signal handler for graceful shutdown
        signal.signal(signal.SIGINT, self._signal_handler)
        signal.signal(signal.SIGTERM, self._signal_handler)
    
    def _signal_handler(self, signum, frame):
        """Handle interruption signals gracefully."""
        logger.info("Received interrupt signal. Finishing current request and saving progress...")
        self.interrupted = True
    
    def get_last_run_state(self) -> Optional[Dict[str, Any]]:
        """
        Get the last run state from local file
        """
        try:
            if self.state_file.exists():
                with open(self.state_file, 'r', encoding='utf-8') as f:
                    return json.load(f)
            else:
                logger.info("No previous run state found - this is the first run")
                return None
        except Exception as e:
            logger.warning(f"Error reading last run state: {str(e)}")
            return None
    
    def save_run_state(self, last_processed_timestamp: int, run_timestamp: str):
        """
        Save the current run state to local file
        """
        state = {
            'last_processed_timestamp': last_processed_timestamp,
            'run_timestamp': run_timestamp,
            'last_run_date': datetime.fromtimestamp(last_processed_timestamp).strftime('%Y-%m-%d')
        }
        
        try:
            self.state_file.parent.mkdir(parents=True, exist_ok=True)
            with open(self.state_file, 'w', encoding='utf-8') as f:
                json.dump(state, f, indent=2, default=str)
            logger.info(f"Saved run state: last_processed_timestamp={last_processed_timestamp}")
        except Exception as e:
            logger.error(f"Error saving run state: {str(e)}")
    
    def determine_date_range(self) -> tuple[int, Optional[int]]:
        """
        Determine the date range to process based on previous runs and configuration
        Returns (since_timestamp, until_timestamp)
        """
        now = datetime.now(timezone.utc)
        current_timestamp = int(now.timestamp())
        
        # If manual since_timestamp provided, use it
        if self.config.since_timestamp:
            logger.info(f"Using manual since_timestamp: {self.config.since_timestamp}")
            return self.config.since_timestamp, None
        
        # If smart incremental is disabled, start from initial date
        if not self.config.enable_smart_incremental:
            since_timestamp = int(self.config.initial_start_date.timestamp())
            logger.info(f"Smart incremental disabled - processing from {self.config.initial_start_date.strftime('%Y-%m-%d')}")
            return since_timestamp, None
        
        # Smart incremental logic
        last_state = self.get_last_run_state()
        
        if last_state is None:
            # First run: start from July 2, 2025
            since_timestamp = int(self.config.initial_start_date.timestamp())
            logger.info(f"First run detected - processing from {self.config.initial_start_date.strftime('%Y-%m-%d')} to today")
            return since_timestamp, current_timestamp
        else:
            # Subsequent runs: start from last processed timestamp + 1 second
            since_timestamp = last_state.get('last_processed_timestamp', int(self.config.initial_start_date.timestamp())) + 1
            last_date = datetime.fromtimestamp(since_timestamp).strftime('%Y-%m-%d')
            logger.info(f"Incremental run - processing from {last_date} onwards")
            return since_timestamp, current_timestamp
    
    def _setup_session(self) -> requests.Session:
        """Setup HTTP session with authentication and headers."""
        session = requests.Session()
        session.headers.update({
            'Authorization': f'Bearer {self.config.api_key}',
            'Content-Type': 'application/json',
            'User-Agent': 'OpenAI-Compliance-Downloader/1.0'
        })
        return session
    
    def _make_request(self, endpoint: str, params: Dict[str, Any] = None) -> Optional[Dict[str, Any]]:
        """Make a request to the API with retries and rate limiting."""
        url = urljoin(self.config.base_url, endpoint)
        
        for attempt in range(self.config.max_retries):
            try:
                self.stats['total_requests'] += 1
                
                logger.debug(f"Making request to {url} with params: {params}")
                response = self.session.get(
                    url, 
                    params=params, 
                    timeout=self.config.timeout
                )
                
                if response.status_code == 200:
                    return response.json()
                elif response.status_code == 404:
                    logger.error(f"Resource not found (404): {url}")
                    logger.error("Check your workspace_id and API permissions")
                    return None
                elif response.status_code == 429:
                    # Rate limited
                    retry_after = int(response.headers.get('Retry-After', 60))
                    logger.warning(f"Rate limited. Waiting {retry_after} seconds...")
                    time.sleep(retry_after)
                    continue
                elif response.status_code == 401:
                    logger.error("Authentication failed (401). Check your API key.")
                    return None
                elif response.status_code == 403:
                    logger.error("Access forbidden (403). Check your API key permissions.")
                    return None
                else:
                    logger.warning(f"Request failed with status {response.status_code}: {response.text}")
                    
            except requests.exceptions.RequestException as e:
                logger.error(f"Request exception on attempt {attempt + 1}: {str(e)}")
                if attempt == self.config.max_retries - 1:
                    self.stats['failed_requests'] += 1
                    return None
                time.sleep(2 ** attempt)  # Exponential backoff
        
        return None
    
    def _get_conversations_page(self, after: Optional[str] = None, since_timestamp: Optional[int] = None) -> Optional[Dict[str, Any]]:
        """Get a single page of conversations."""
        endpoint = f"compliance/workspaces/{self.config.workspace_id}/conversations"
        
        params = {
            'limit': self.config.batch_size
        }
        
        # Handle pagination and timestamp parameters
        if after and since_timestamp:
            # Both provided - use after for pagination, since_timestamp for first request only
            params['after'] = after
        elif after:
            # Only after provided (subsequent pages)
            params['after'] = after
        elif since_timestamp:
            # Only since_timestamp provided (first request)
            params['since_timestamp'] = since_timestamp
        
        if self.config.specific_users:
            # API supports multiple users parameter
            for user in self.config.specific_users:
                params['users'] = user  # Note: This may need to be handled differently
        
        # Rate limiting
        time.sleep(self.config.rate_limit_delay)
        
        return self._make_request(endpoint, params)
    
    def _extract_timestamp(self, conversation: Dict[str, Any]) -> int:
        """
        Extract timestamp from conversation for filtering
        """
        # Try different timestamp fields
        for field in ['updated_at', 'created_at', 'last_active_at']:
            if field in conversation:
                timestamp = conversation[field]
                if isinstance(timestamp, (int, float)):
                    return int(timestamp)
                try:
                    # Handle ISO format
                    dt = datetime.fromisoformat(timestamp.replace('Z', '+00:00'))
                    return int(dt.timestamp())
                except (ValueError, AttributeError):
                    continue
        
        # Default to current time if no valid timestamp found
        return int(datetime.utcnow().timestamp())
    
    def _organize_conversations_by_user_date(self, conversations: List[Dict[str, Any]]) -> Dict[str, Dict[str, List[Dict[str, Any]]]]:
        """Organize conversations by user ID and date."""
        organized = {}
        
        for conversation in conversations:
            # Extract user information
            user_id = self._extract_user_id(conversation)
            if not user_id:
                user_id = "unknown_user"
            
            # Extract date from conversation
            date_str = self._extract_date(conversation)
            if not date_str:
                date_str = datetime.now().strftime('%Y-%m-%d')
            
            # Initialize nested structure
            if user_id not in organized:
                organized[user_id] = {}
            if date_str not in organized[user_id]:
                organized[user_id][date_str] = []
            
            organized[user_id][date_str].append(conversation)
        
        return organized
    
    def _extract_user_id(self, conversation: Dict[str, Any]) -> str:
        """Extract user ID from conversation data."""
        # Try different possible locations for user ID
        user_id = None
        
        if 'user_id' in conversation:
            user_id = conversation['user_id']
        elif 'owner' in conversation and 'user_id' in conversation['owner']:
            user_id = conversation['owner']['user_id']
        elif 'created_by' in conversation:
            user_id = conversation['created_by']
        elif 'participants' in conversation and len(conversation['participants']) > 0:
            user_id = conversation['participants'][0].get('user_id')
        
        return user_id or "unknown_user"
    
    def _extract_date(self, conversation: Dict[str, Any]) -> str:
        """Extract date from conversation data."""
        # Try different timestamp fields
        timestamp = None
        
        for field in ['created_at', 'updated_at', 'last_active_at', 'created_time', 'update_time']:
            if field in conversation:
                timestamp = conversation[field]
                break
        
        if timestamp:
            try:
                # Handle both Unix timestamp and ISO format
                if isinstance(timestamp, (int, float)):
                    dt = datetime.fromtimestamp(timestamp)
                else:
                    dt = datetime.fromisoformat(timestamp.replace('Z', '+00:00'))
                return dt.strftime('%Y-%m-%d')
            except (ValueError, TypeError):
                logger.warning(f"Could not parse timestamp: {timestamp}")
        
        return datetime.now().strftime('%Y-%m-%d')
    
    def _save_conversations_to_file(self, user_id: str, date: str, conversations: List[Dict[str, Any]], output_dir: Path):
        """Save conversations to organized file structure."""
        # Create directory structure: output_dir/user_id/YYYY/MM/DD/
        date_obj = datetime.strptime(date, '%Y-%m-%d')
        year = date_obj.strftime('%Y')
        month = date_obj.strftime('%m')
        day = date_obj.strftime('%d')
        
        user_dir = output_dir / user_id / year / month / day
        user_dir.mkdir(parents=True, exist_ok=True)
        
        # Prepare data for storage
        file_data = {
            'date': date,
            'user_id': user_id,
            'conversation_count': len(conversations),
            'conversations': conversations,
            'metadata': {
                'download_timestamp': datetime.now().isoformat(),
                'source': 'local_compliance_downloader'
            }
        }
        
        # Save to file
        file_path = user_dir / 'conversations.json'
        with open(file_path, 'w', encoding='utf-8') as f:
            json.dump(file_data, f, indent=2, ensure_ascii=False, default=str)
        
        logger.info(f"Saved {len(conversations)} conversations for {user_id} on {date} to {file_path}")
        return file_path
    
    def _save_daily_summary(self, organized_data: Dict[str, Dict[str, List[Dict[str, Any]]]], output_dir: Path):
        """Save daily summary with statistics."""
        summary_dir = output_dir / "_daily_summaries"
        summary_dir.mkdir(parents=True, exist_ok=True)
        
        # Group by date across all users
        date_summaries = {}
        
        for user_id, date_data in organized_data.items():
            for date, conversations in date_data.items():
                if date not in date_summaries:
                    date_summaries[date] = {
                        'date': date,
                        'total_users': 0,
                        'total_conversations': 0,
                        'user_statistics': {}
                    }
                
                date_summaries[date]['total_users'] += 1
                date_summaries[date]['total_conversations'] += len(conversations)
                date_summaries[date]['user_statistics'][user_id] = {
                    'conversation_count': len(conversations),
                    'total_messages': sum(
                        len(conv.get('messages', []))
                        for conv in conversations
                    )
                }
        
        # Save each date summary
        for date, summary in date_summaries.items():
            date_obj = datetime.strptime(date, '%Y-%m-%d')
            year = date_obj.strftime('%Y')
            month = date_obj.strftime('%m')
            day = date_obj.strftime('%d')
            
            date_dir = summary_dir / year / month / day
            date_dir.mkdir(parents=True, exist_ok=True)
            
            summary['download_timestamp'] = datetime.now().isoformat()
            
            file_path = date_dir / 'summary.json'
            with open(file_path, 'w', encoding='utf-8') as f:
                json.dump(summary, f, indent=2, ensure_ascii=False, default=str)
            
            logger.info(f"Saved daily summary for {date} to {file_path}")
    
    def _save_progress(self, last_id: str, output_dir: Path):
        """Save download progress for resume capability."""
        progress_file = output_dir / ".download_progress.json"
        progress = {
            'last_id': last_id,
            'timestamp': datetime.now().isoformat(),
            'stats': self.stats
        }
        
        with open(progress_file, 'w', encoding='utf-8') as f:
            json.dump(progress, f, indent=2, default=str)
    
    def _load_progress(self, output_dir: Path) -> Optional[str]:
        """Load previous download progress."""
        progress_file = output_dir / ".download_progress.json"
        
        if not progress_file.exists():
            return None
        
        try:
            with open(progress_file, 'r', encoding='utf-8') as f:
                progress = json.load(f)
            
            logger.info(f"Resuming from last_id: {progress.get('last_id')}")
            return progress.get('last_id')
        
        except (json.JSONDecodeError, KeyError) as e:
            logger.warning(f"Could not load progress file: {e}")
            return None
    
    def download_all_conversations(self, resume: bool = True) -> bool:
        """Download conversations from the workspace using smart date range logic."""
        logger.info("Starting conversation download with smart date range processing...")
        logger.info(f"Workspace ID: {self.config.workspace_id}")
        logger.info(f"Output directory: {self.config.output_dir}")
        
        output_dir = Path(self.config.output_dir)
        output_dir.mkdir(parents=True, exist_ok=True)
        
        # Determine date range for processing
        since_timestamp, until_timestamp = self.determine_date_range()
        since_date = datetime.fromtimestamp(since_timestamp).strftime('%Y-%m-%d')
        until_date = datetime.fromtimestamp(until_timestamp).strftime('%Y-%m-%d') if until_timestamp else "now"
        
        logger.info(f"Processing conversations from {since_date} to {until_date}")
        
        # Load progress if resuming (for pagination within the date range)
        after = None
        if resume:
            after = self._load_progress(output_dir)
        
        all_conversations = []
        page_count = 0
        
        try:
            while not self.interrupted:
                page_count += 1
                logger.info(f"Downloading page {page_count}...")
                
                # Get conversations page with smart timestamp handling
                if page_count == 1:
                    # Use since_timestamp for first request
                    response = self._get_conversations_page(since_timestamp=since_timestamp, after=after)
                else:
                    # Subsequent pages use after parameter only
                    response = self._get_conversations_page(after=after)
                
                if not response:
                    logger.error("Failed to get conversations page")
                    return False
                
                conversations = response.get('data', [])
                if not conversations:
                    logger.info("No more conversations to download")
                    break
                
                # Filter conversations by until_timestamp if specified
                if until_timestamp:
                    filtered_conversations = []
                    for conv in conversations:
                        conv_timestamp = self._extract_timestamp(conv)
                        if conv_timestamp <= until_timestamp:
                            filtered_conversations.append(conv)
                    conversations = filtered_conversations
                
                logger.info(f"Downloaded {len(conversations)} conversations from page {page_count}")
                all_conversations.extend(conversations)
                self.stats['total_conversations'] += len(conversations)
                
                # Save progress
                last_id = response.get('last_id')
                if last_id:
                    self._save_progress(last_id, output_dir)
                
                # Check if there are more pages
                has_more = response.get('has_more', False)
                if not has_more:
                    logger.info("Downloaded all available conversations")
                    break
                
                # Set up for next page
                after = last_id
                
                # Show progress
                if page_count % 10 == 0:
                    elapsed = datetime.now() - self.stats['start_time']
                    logger.info(f"Progress: {self.stats['total_conversations']} conversations, "
                              f"{page_count} pages, "
                              f"{elapsed.total_seconds():.1f}s elapsed")
        
        except Exception as e:
            logger.error(f"Error during download: {str(e)}")
            return False
        
        if not all_conversations:
            logger.info("No conversations found for the specified time range")
            
            # Still save the run state even if no data found (for smart incremental)
            if self.config.enable_smart_incremental and until_timestamp:
                self.save_run_state(until_timestamp, datetime.now().isoformat())
            
            return True
        
        # Calculate max processed timestamp for state tracking
        max_processed_timestamp = max(
            self._extract_timestamp(conv) for conv in all_conversations
        ) if all_conversations else (until_timestamp or int(datetime.utcnow().timestamp()))
        
        # Organize conversations by user and date
        logger.info("Organizing conversations by user and date...")
        organized_data = self._organize_conversations_by_user_date(all_conversations)
        self.stats['total_users'] = len(organized_data)
        
        # Save organized data to files
        logger.info("Saving conversations to files...")
        for user_id, date_data in organized_data.items():
            for date, conversations in date_data.items():
                self._save_conversations_to_file(user_id, date, conversations, output_dir)
        
        # Save daily summaries
        logger.info("Saving daily summaries...")
        self._save_daily_summary(organized_data, output_dir)
        
        # Save run state for next execution (smart incremental)
        if self.config.enable_smart_incremental:
            self.save_run_state(max_processed_timestamp, datetime.now().isoformat())
        
        # Clean up progress file (pagination state)
        progress_file = output_dir / ".download_progress.json"
        if progress_file.exists():
            progress_file.unlink()
        
        # Final statistics
        elapsed = datetime.now() - self.stats['start_time']
        logger.info("Download completed!")
        logger.info(f"Statistics:")
        logger.info(f"  Total conversations: {self.stats['total_conversations']}")
        logger.info(f"  Total users: {self.stats['total_users']}")
        logger.info(f"  Total requests: {self.stats['total_requests']}")
        logger.info(f"  Failed requests: {self.stats['failed_requests']}")
        logger.info(f"  Time elapsed: {elapsed.total_seconds():.1f} seconds")
        logger.info(f"  Date range: {since_date} to {until_date}")
        logger.info(f"  Max processed timestamp: {max_processed_timestamp}")
        logger.info(f"  Output directory: {output_dir.absolute()}")
        
        return True

def load_config_from_file(config_file: str) -> Dict[str, str]:
    """Load configuration from environment file."""
    config = {}
    
    if not os.path.exists(config_file):
        logger.error(f"Config file not found: {config_file}")
        return config
    
    with open(config_file, 'r') as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#') and '=' in line:
                key, value = line.split('=', 1)
                # Remove export prefix and quotes
                key = key.replace('export ', '').strip()
                value = value.strip().strip('\'"')
                config[key] = value
    
    return config

def main():
    """Main function with argument parsing."""
    parser = argparse.ArgumentParser(
        description="Download all conversations from OpenAI Compliance API",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Download all conversations
  python download_local.py --workspace-id ws-123 --api-key sk-...
  
  # Load configuration from file
  python download_local.py --config .env
  
  # Download conversations since specific timestamp
  python download_local.py --config .env --since-timestamp 1640995200
  
  # Download for specific users only
  python download_local.py --config .env --users user-123 user-456
  
  # Custom output directory
  python download_local.py --config .env --output-dir /path/to/backups
        """
    )
    
    parser.add_argument('--workspace-id', help='ChatGPT Enterprise workspace ID')
    parser.add_argument('--api-key', help='OpenAI API key with compliance_export permissions')
    parser.add_argument('--config', help='Configuration file to load settings from')
    parser.add_argument('--output-dir', default='./downloads', help='Output directory (default: ./downloads)')
    parser.add_argument('--since-timestamp', type=int, help='Download conversations since Unix timestamp')
    parser.add_argument('--users', nargs='*', help='Download conversations for specific user IDs only')
    parser.add_argument('--no-resume', action='store_true', help='Do not resume from previous download')
    parser.add_argument('--rate-limit-delay', type=float, default=1.2, 
                       help='Delay between API requests in seconds (default: 1.2)')
    parser.add_argument('--no-smart-incremental', action='store_true', 
                       help='Disable smart incremental downloads (always start from July 2, 2025)')
    parser.add_argument('--debug', action='store_true', help='Enable debug logging')
    
    args = parser.parse_args()
    
    if args.debug:
        logging.getLogger().setLevel(logging.DEBUG)
    
    # Load configuration
    config_data = {}
    if args.config:
        config_data = load_config_from_file(args.config)
    
    # Get API credentials
    api_key = args.api_key or config_data.get('OPENAI_API_KEY') or os.getenv('OPENAI_API_KEY')
    workspace_id = args.workspace_id or config_data.get('WORKSPACE_ID') or os.getenv('WORKSPACE_ID')
    
    if not api_key:
        logger.error("API key is required. Provide via --api-key, config file, or OPENAI_API_KEY env var")
        sys.exit(1)
    
    if not workspace_id:
        logger.error("Workspace ID is required. Provide via --workspace-id, config file, or WORKSPACE_ID env var")
        sys.exit(1)
    
    # Get additional configuration options
    enable_smart_incremental = config_data.get('ENABLE_SMART_INCREMENTAL', 'true').lower() == 'true'
    if args.no_smart_incremental:
        enable_smart_incremental = False
    
    # Create download configuration
    config = DownloadConfig(
        api_key=api_key,
        workspace_id=workspace_id,
        output_dir=args.output_dir,
        rate_limit_delay=args.rate_limit_delay,
        since_timestamp=args.since_timestamp,
        specific_users=args.users,
        enable_smart_incremental=enable_smart_incremental
    )
    
    # Start download
    downloader = ComplianceDownloader(config)
    success = downloader.download_all_conversations(resume=not args.no_resume)
    
    if success:
        logger.info("Download completed successfully!")
        sys.exit(0)
    else:
        logger.error("Download failed!")
        sys.exit(1)

if __name__ == '__main__':
    main()
