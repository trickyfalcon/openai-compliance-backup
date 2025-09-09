import json
import boto3
import requests
import os
import time
from datetime import datetime, timedelta
from typing import Dict, List, Any, Optional
import logging

# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

class OpenAIComplianceBackup:
    def __init__(self):
        self.openai_api_key = os.environ.get('OPENAI_API_KEY')
        self.workspace_id = os.environ.get('WORKSPACE_ID')
        self.s3_bucket = os.environ.get('S3_BUCKET_NAME')
        self.s3_client = boto3.client('s3')
        
        # Constants for data pulling strategy
        self.INITIAL_START_DATE = datetime(2025, 7, 2)  # July 2nd, 2025
        self.STATE_FILE_KEY = '_backup_state/last_run.json'
        
        if not all([self.openai_api_key, self.workspace_id, self.s3_bucket]):
            raise ValueError("Missing required environment variables: OPENAI_API_KEY, WORKSPACE_ID, or S3_BUCKET_NAME")
    
    def get_last_run_state(self) -> Optional[Dict[str, Any]]:
        """
        Get the last run state from S3
        """
        try:
            response = self.s3_client.get_object(Bucket=self.s3_bucket, Key=self.STATE_FILE_KEY)
            return json.loads(response['Body'].read().decode('utf-8'))
        except self.s3_client.exceptions.NoSuchKey:
            logger.info("No previous run state found - this is the first run")
            return None
        except Exception as e:
            logger.warning(f"Error reading last run state: {str(e)}")
            return None
    
    def save_run_state(self, last_processed_timestamp: int, run_timestamp: str):
        """
        Save the current run state to S3
        """
        state = {
            'last_processed_timestamp': last_processed_timestamp,
            'run_timestamp': run_timestamp,
            'last_run_date': datetime.fromtimestamp(last_processed_timestamp).strftime('%Y-%m-%d')
        }
        
        try:
            self.s3_client.put_object(
                Bucket=self.s3_bucket,
                Key=self.STATE_FILE_KEY,
                Body=json.dumps(state, indent=2, default=str),
                ContentType='application/json',
                ServerSideEncryption='AES256'
            )
            logger.info(f"Saved run state: last_processed_timestamp={last_processed_timestamp}")
        except Exception as e:
            logger.error(f"Error saving run state: {str(e)}")
    
    def determine_date_range(self) -> tuple[int, int]:
        """
        Determine the date range to process based on previous runs
        Returns (since_timestamp, until_timestamp)
        """
        now = datetime.utcnow()
        current_timestamp = int(now.timestamp())
        
        # Get last run state
        last_state = self.get_last_run_state()
        
        if last_state is None:
            # First run: start from July 2, 2025
            since_timestamp = int(self.INITIAL_START_DATE.timestamp())
            logger.info(f"First run detected - processing from {self.INITIAL_START_DATE.strftime('%Y-%m-%d')} to today")
        else:
            # Subsequent runs: start from last processed timestamp + 1 second
            since_timestamp = last_state.get('last_processed_timestamp', int(self.INITIAL_START_DATE.timestamp())) + 1
            last_date = datetime.fromtimestamp(since_timestamp).strftime('%Y-%m-%d')
            logger.info(f"Incremental run - processing from {last_date} onwards")
        
        return since_timestamp, current_timestamp
    
    def get_compliance_data(self, since_timestamp: int, until_timestamp: Optional[int] = None) -> List[Dict[Any, Any]]:
        """
        Fetch compliance data from OpenAI API for a timestamp range
        """
        headers = {
            'Authorization': f'Bearer {self.openai_api_key}',
            'Content-Type': 'application/json'
        }
        
        # OpenAI Compliance API endpoint (correct endpoint from documentation)
        url = f'https://api.chatgpt.com/v1/compliance/workspaces/{self.workspace_id}/conversations'
        
        params = {
            'limit': 500,  # Maximum allowed by API
            'since_timestamp': since_timestamp
        }
        
        all_conversations = []
        page_count = 0
        
        try:
            while True:
                page_count += 1
                logger.info(f"Fetching page {page_count} from OpenAI API...")
                
                # Add rate limiting
                time.sleep(1.2)  # 50 requests per minute limit
                
                response = requests.get(url, headers=headers, params=params, timeout=30)
                response.raise_for_status()
                
                data = response.json()
                conversations = data.get('data', [])
                
                if not conversations:
                    logger.info("No more conversations to fetch")
                    break
                
                # Filter conversations by until_timestamp if specified
                filtered_conversations = []
                for conv in conversations:
                    conv_timestamp = self._extract_timestamp(conv)
                    if until_timestamp and conv_timestamp > until_timestamp:
                        continue
                    filtered_conversations.append(conv)
                
                all_conversations.extend(filtered_conversations)
                logger.info(f"Page {page_count}: retrieved {len(filtered_conversations)} conversations")
                
                # Check pagination
                if not data.get('has_more', False):
                    break
                
                # Set up next page
                params['after'] = data.get('last_id')
                if 'since_timestamp' in params:
                    del params['since_timestamp']  # Only use since_timestamp on first request
            
            logger.info(f"Retrieved {len(all_conversations)} total conversations")
            return all_conversations
            
        except requests.exceptions.RequestException as e:
            logger.error(f"Error fetching data from OpenAI API: {str(e)}")
            raise
    
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
    
    def organize_conversations_by_user(self, conversations: List[Dict[Any, Any]]) -> Dict[str, List[Dict[Any, Any]]]:
        """
        Organize conversations by user ID (legacy method for backwards compatibility)
        """
        user_conversations = {}
        
        for conversation in conversations:
            user_id = self._extract_user_id(conversation)
            if user_id not in user_conversations:
                user_conversations[user_id] = []
            user_conversations[user_id].append(conversation)
        
        return user_conversations
    
    def organize_conversations_by_user_and_date(self, conversations: List[Dict[Any, Any]]) -> Dict[str, Dict[str, List[Dict[Any, Any]]]]:
        """
        Organize conversations by user ID and date
        """
        organized = {}
        
        for conversation in conversations:
            # Extract user information
            user_id = self._extract_user_id(conversation)
            
            # Extract date from conversation
            timestamp = self._extract_timestamp(conversation)
            date_str = datetime.fromtimestamp(timestamp).strftime('%Y-%m-%d')
            
            # Initialize nested structure
            if user_id not in organized:
                organized[user_id] = {}
            if date_str not in organized[user_id]:
                organized[user_id][date_str] = []
            
            organized[user_id][date_str].append(conversation)
        
        return organized
    
    def _extract_user_id(self, conversation: Dict[str, Any]) -> str:
        """
        Extract user ID from conversation data
        """
        # Try different possible locations for user ID
        if 'user_id' in conversation:
            return conversation['user_id']
        elif 'owner' in conversation and isinstance(conversation['owner'], dict):
            return conversation['owner'].get('user_id', 'unknown_user')
        elif 'created_by' in conversation:
            return conversation['created_by']
        elif 'participants' in conversation and len(conversation['participants']) > 0:
            return conversation['participants'][0].get('user_id', 'unknown_user')
        
        return 'unknown_user'
    
    def upload_to_s3(self, data: Dict[str, List[Dict[Any, Any]]], date: str):
        """
        Upload organized data to S3 with structure: bucket/user_id/yyyy/mm/dd/conversations.json (legacy method)
        """
        for user_id, conversations in data.items():
            self.upload_to_s3_by_date(user_id, date, conversations)
    
    def upload_to_s3_by_date(self, user_id: str, date: str, conversations: List[Dict[Any, Any]]):
        """
        Upload conversations for a specific user and date to S3
        """
        date_obj = datetime.strptime(date, '%Y-%m-%d')
        year = date_obj.strftime('%Y')
        month = date_obj.strftime('%m')
        day = date_obj.strftime('%d')
        
        # Create S3 key with hierarchical structure
        s3_key = f"{user_id}/{year}/{month}/{day}/conversations.json"
        
        # Prepare data for storage
        storage_data = {
            'date': date,
            'user_id': user_id,
            'conversation_count': len(conversations),
            'conversations': conversations,
            'metadata': {
                'backup_timestamp': datetime.utcnow().isoformat(),
                'lambda_function': 'openai-compliance-backup',
                'python_version': '3.12'
            }
        }
        
        try:
            # Upload to S3
            self.s3_client.put_object(
                Bucket=self.s3_bucket,
                Key=s3_key,
                Body=json.dumps(storage_data, indent=2, default=str),
                ContentType='application/json',
                ServerSideEncryption='AES256'
            )
            
            logger.info(f"Successfully uploaded {len(conversations)} conversations for user {user_id} on {date} to s3://{self.s3_bucket}/{s3_key}")
            
        except Exception as e:
            logger.error(f"Error uploading to S3 for user {user_id} on {date}: {str(e)}")
            raise
    
    def create_daily_summary(self, user_data: Dict[str, List[Dict[Any, Any]]], date: str):
        """
        Create a daily summary file with aggregate statistics (legacy method)
        """
        date_obj = datetime.strptime(date, '%Y-%m-%d')
        year = date_obj.strftime('%Y')
        month = date_obj.strftime('%m')
        day = date_obj.strftime('%d')
        
        summary = {
            'date': date,
            'total_users': len(user_data),
            'total_conversations': sum(len(conversations) for conversations in user_data.values()),
            'user_statistics': {
                user_id: {
                    'conversation_count': len(conversations),
                    'total_messages': sum(len(conv.get('messages', [])) for conv in conversations)
                }
                for user_id, conversations in user_data.items()
            },
            'backup_timestamp': datetime.utcnow().isoformat()
        }
        
        s3_key = f"_daily_summaries/{year}/{month}/{day}/summary.json"
        
        try:
            self.s3_client.put_object(
                Bucket=self.s3_bucket,
                Key=s3_key,
                Body=json.dumps(summary, indent=2, default=str),
                ContentType='application/json',
                ServerSideEncryption='AES256'
            )
            
            logger.info(f"Successfully uploaded daily summary to s3://{self.s3_bucket}/{s3_key}")
            
        except Exception as e:
            logger.error(f"Error uploading daily summary: {str(e)}")
            raise
    
    def create_daily_summaries(self, user_conversations: Dict[str, Dict[str, List[Dict[Any, Any]]]]):
        """
        Create daily summary files for all dates in the dataset
        """
        # Group by date across all users
        date_summaries = {}
        
        for user_id, date_data in user_conversations.items():
            for date_str, conversations in date_data.items():
                if date_str not in date_summaries:
                    date_summaries[date_str] = {
                        'date': date_str,
                        'total_users': 0,
                        'total_conversations': 0,
                        'user_statistics': {}
                    }
                
                date_summaries[date_str]['total_users'] += 1
                date_summaries[date_str]['total_conversations'] += len(conversations)
                date_summaries[date_str]['user_statistics'][user_id] = {
                    'conversation_count': len(conversations),
                    'total_messages': sum(
                        len(conv.get('messages', []))
                        for conv in conversations
                    )
                }
        
        # Save each date summary
        for date_str, summary_data in date_summaries.items():
            date_obj = datetime.strptime(date_str, '%Y-%m-%d')
            year = date_obj.strftime('%Y')
            month = date_obj.strftime('%m')
            day = date_obj.strftime('%d')
            
            summary_data['backup_timestamp'] = datetime.utcnow().isoformat()
            summary_data['python_version'] = '3.12'
            
            s3_key = f"_daily_summaries/{year}/{month}/{day}/summary.json"
            
            try:
                self.s3_client.put_object(
                    Bucket=self.s3_bucket,
                    Key=s3_key,
                    Body=json.dumps(summary_data, indent=2, default=str),
                    ContentType='application/json',
                    ServerSideEncryption='AES256'
                )
                
                logger.info(f"Successfully uploaded daily summary for {date_str} to s3://{self.s3_bucket}/{s3_key}")
                
            except Exception as e:
                logger.error(f"Error uploading daily summary for {date_str}: {str(e)}")
                raise

def lambda_handler(event, context):
    """
    AWS Lambda handler function with smart date range processing
    """
    try:
        # Initialize the backup service
        backup_service = OpenAIComplianceBackup()
        
        # Determine date range for processing
        since_timestamp, until_timestamp = backup_service.determine_date_range()
        
        # Allow manual override of date range via event
        if event.get('since_timestamp'):
            since_timestamp = int(event['since_timestamp'])
            logger.info(f"Manual override: since_timestamp={since_timestamp}")
        
        if event.get('until_timestamp'):
            until_timestamp = int(event['until_timestamp'])
            logger.info(f"Manual override: until_timestamp={until_timestamp}")
        
        since_date = datetime.fromtimestamp(since_timestamp).strftime('%Y-%m-%d')
        until_date = datetime.fromtimestamp(until_timestamp).strftime('%Y-%m-%d')
        
        logger.info(f"Starting OpenAI compliance backup from {since_date} to {until_date}")
        
        # Fetch compliance data for the determined range
        conversations = backup_service.get_compliance_data(since_timestamp, until_timestamp)
        
        if not conversations:
            logger.info(f"No conversations found for the specified time range")
            
            # Still save the run state even if no data found
            backup_service.save_run_state(until_timestamp, datetime.utcnow().isoformat())
            
            return {
                'statusCode': 200,
                'body': json.dumps({
                    'message': f'No conversations found for time range {since_date} to {until_date}',
                    'since_date': since_date,
                    'until_date': until_date,
                    'since_timestamp': since_timestamp,
                    'until_timestamp': until_timestamp
                })
            }
        
        # Organize conversations by user and date
        user_conversations = backup_service.organize_conversations_by_user_and_date(conversations)
        
        # Upload organized data to S3
        total_files_uploaded = 0
        for user_id, date_data in user_conversations.items():
            for date_str, date_conversations in date_data.items():
                backup_service.upload_to_s3_by_date(user_id, date_str, date_conversations)
                total_files_uploaded += 1
        
        # Create daily summaries for each date
        backup_service.create_daily_summaries(user_conversations)
        
        # Save the run state for next execution
        backup_service.save_run_state(until_timestamp, datetime.utcnow().isoformat())
        
        # Calculate max timestamp of processed conversations
        max_processed_timestamp = max(
            backup_service._extract_timestamp(conv) 
            for conv in conversations
        ) if conversations else until_timestamp
        
        logger.info(f"Successfully completed backup - processed {len(conversations)} conversations")
        
        return {
            'statusCode': 200,
            'body': json.dumps({
                'message': 'Backup completed successfully',
                'since_date': since_date,
                'until_date': until_date,
                'since_timestamp': since_timestamp,
                'until_timestamp': until_timestamp,
                'max_processed_timestamp': max_processed_timestamp,
                'total_users': len(user_conversations),
                'total_conversations': len(conversations),
                'total_files_uploaded': total_files_uploaded
            })
        }
        
    except Exception as e:
        logger.error(f"Error in lambda_handler: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps({
                'error': str(e),
                'message': 'Backup failed'
            })
        }
