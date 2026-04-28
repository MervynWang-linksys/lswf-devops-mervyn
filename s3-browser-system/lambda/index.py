import json
import boto3
import os

s3 = boto3.client('s3')

def lambda_handler(event, context):
    bucket_name = os.environ['BUCKET_NAME']
    output_key = 's3-browser/files.json'

    try:
        # EventBridge scheduled event or manual invoke — always full scan
        if 'source' in event and event['source'] == 'aws.events':
            file_list = perform_full_scan(bucket_name, output_key)
        elif not event.get('Records'):
            file_list = perform_full_scan(bucket_name, output_key)
        else:
            # S3 event: incremental update
            try:
                response = s3.get_object(Bucket=bucket_name, Key=output_key)
                file_list = json.loads(response['Body'].read().decode('utf-8'))
            except s3.exceptions.NoSuchKey:
                file_list = perform_full_scan(bucket_name, output_key)

            for record in event.get('Records', []):
                event_name = record['eventName']
                changed_key = record['s3']['object']['key']
                if changed_key == output_key:
                    continue
                if event_name.startswith('ObjectCreated'):
                    update_file_entry(bucket_name, changed_key, file_list)
                elif event_name.startswith('ObjectRemoved'):
                    remove_file_entry(changed_key, file_list)

        s3.put_object(
            Bucket=bucket_name,
            Key=output_key,
            Body=json.dumps(file_list, indent=2),
            ContentType='application/json',
        )

        return {
            'statusCode': 200,
            'body': json.dumps(f'files.json updated. Total: {len(file_list)}'),
        }

    except Exception as e:
        print(f"Error: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps(f'Error: {str(e)}'),
        }


def perform_full_scan(bucket_name, output_key):
    """Perform full bucket scan for initialization"""
    paginator = s3.get_paginator('list_objects_v2')
    file_list = []
    
    for page in paginator.paginate(Bucket=bucket_name):
        if 'Contents' in page:
            for obj in page['Contents']:
                if obj['Key'] == output_key:
                    continue
                file_list.append({
                    'key': obj['Key'],
                    'size': obj['Size'],
                    'last_modified': obj['LastModified'].isoformat()
                })
    
    return file_list


def update_file_entry(bucket_name, key, file_list):
    """Add or update a single file entry"""
    try:
        # Get object metadata
        response = s3.head_object(Bucket=bucket_name, Key=key)
        
        # Remove old entry if exists
        file_list[:] = [f for f in file_list if f['key'] != key]
        
        # Add new entry
        file_list.append({
            'key': key,
            'size': response['ContentLength'],
            'last_modified': response['LastModified'].isoformat()
        })
        
        # Sort by key for consistent ordering
        file_list.sort(key=lambda x: x['key'])
        
    except Exception as e:
        print(f"Error updating file entry for {key}: {str(e)}")


def remove_file_entry(key, file_list):
    """Remove a file entry from the list"""
    file_list[:] = [f for f in file_list if f['key'] != key]
