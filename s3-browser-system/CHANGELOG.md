# Changelog - S3 Browser System

## [v2.0] - Incremental Update Implementation

### 🎯 Changes

**Before:**
- Lambda rescanned entire bucket on every S3 event
- Performance degraded with bucket size (O(n) objects per event)
- High read costs for large buckets

**After:**
- Incremental updates: only processes changed file
- Full scan only on first run (files.json missing)
- Performance: O(1) per event
- Cost reduction: ~99% fewer S3 API calls for buckets with >100 objects

---

### 🔧 Technical Details

#### Event Processing Logic

```
ObjectCreated → head_object(changed_key) → update entry → sort list
ObjectRemoved → filter out entry from list
files.json missing → perform_full_scan() → build initial index
```

#### New Functions

1. **`perform_full_scan(bucket_name, output_key)`**
   - Initial index creation
   - Called only when files.json doesn't exist
   - Returns sorted file list

2. **`update_file_entry(bucket_name, key, file_list)`**
   - Uses `head_object` (cheaper than `list_objects`)
   - Removes old entry + adds updated entry
   - Maintains sorted order by key

3. **`remove_file_entry(key, file_list)`**
   - List comprehension filter
   - In-place modification via slice assignment

---

### 📊 Performance Comparison

| Scenario | Old Version | New Version |
|----------|-------------|-------------|
| 1 file uploaded (1000-object bucket) | 1000 list calls | 1 head call |
| 10 files uploaded | 10,000 list calls | 10 head calls |
| First run (empty files.json) | 1000 list calls | 1000 list calls |

**Cost Example (us-east-1):**
- LIST: $0.005 per 1000 requests
- HEAD: $0.0004 per 1000 requests

For 1000 daily uploads to 10K-object bucket:
- Old: 10M list calls/month = **$50/month**
- New: 1K head calls + 1 list scan = **$0.04/month**

---

### ⚠️ Important Notes

1. **Initial Deployment:** First Lambda invocation will trigger full scan
2. **Manual Trigger:** To rebuild index, delete `s3-browser/files.json`
3. **Event Ordering:** S3 events are not guaranteed ordered; rare race conditions possible
4. **Bucket Size:** Full scan timeout risk for buckets with >100K objects (consider DynamoDB for massive buckets)

---

### 🔄 Migration Steps

1. Deploy updated Lambda code
2. Delete `s3://BUCKET/s3-browser/files.json` to force reindex
3. Upload/delete any file to trigger Lambda
4. Verify files.json generated correctly

---

### 🐛 Error Handling Improvements

- Added try-except around event processing
- Logs errors to CloudWatch
- Returns 500 status on failure (vs silent fail in v1)
- Graceful handling of missing files.json (auto-initialization)
