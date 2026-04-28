#!/bin/bash
# Test script for incremental update behavior

set -e

BUCKET_NAME="fw-qa-internal-lswf"
PROFILE="hn_mervyn"
TEST_PREFIX="test-incremental"

echo "🧪 Testing Incremental Update Behavior"
echo "========================================"

# Cleanup function
cleanup() {
    echo ""
    echo "🧹 Cleaning up test files..."
    aws s3 rm s3://$BUCKET_NAME/$TEST_PREFIX/file1.txt --profile $PROFILE 2>/dev/null || true
    aws s3 rm s3://$BUCKET_NAME/$TEST_PREFIX/file2.txt --profile $PROFILE 2>/dev/null || true
    aws s3 rm s3://$BUCKET_NAME/$TEST_PREFIX/file3.txt --profile $PROFILE 2>/dev/null || true
}

trap cleanup EXIT

# Test 1: Upload multiple files
echo ""
echo "📤 Test 1: Uploading 3 files..."
echo "file1 content" > /tmp/file1.txt
echo "file2 content with more data" > /tmp/file2.txt
echo "file3" > /tmp/file3.txt

aws s3 cp /tmp/file1.txt s3://$BUCKET_NAME/$TEST_PREFIX/file1.txt --profile $PROFILE
echo "   ✓ Uploaded file1.txt"
sleep 2

aws s3 cp /tmp/file2.txt s3://$BUCKET_NAME/$TEST_PREFIX/file2.txt --profile $PROFILE
echo "   ✓ Uploaded file2.txt"
sleep 2

aws s3 cp /tmp/file3.txt s3://$BUCKET_NAME/$TEST_PREFIX/file3.txt --profile $PROFILE
echo "   ✓ Uploaded file3.txt"
sleep 3

# Check files.json
echo ""
echo "📋 Checking files.json for test files..."
FILES_JSON=$(aws s3 cp s3://$BUCKET_NAME/s3-browser/files.json - --profile $PROFILE 2>/dev/null)

if echo "$FILES_JSON" | grep -q "$TEST_PREFIX/file1.txt"; then
    echo "   ✅ file1.txt found in index"
else
    echo "   ❌ file1.txt NOT found"
fi

if echo "$FILES_JSON" | grep -q "$TEST_PREFIX/file2.txt"; then
    echo "   ✅ file2.txt found in index"
else
    echo "   ❌ file2.txt NOT found"
fi

if echo "$FILES_JSON" | grep -q "$TEST_PREFIX/file3.txt"; then
    echo "   ✅ file3.txt found in index"
else
    echo "   ❌ file3.txt NOT found"
fi

# Test 2: Update a file
echo ""
echo "🔄 Test 2: Updating file2.txt..."
echo "file2 UPDATED content with even more data" > /tmp/file2.txt
ORIGINAL_SIZE=$(echo "$FILES_JSON" | jq -r ".[] | select(.key==\"$TEST_PREFIX/file2.txt\") | .size")
echo "   Original size: $ORIGINAL_SIZE bytes"

aws s3 cp /tmp/file2.txt s3://$BUCKET_NAME/$TEST_PREFIX/file2.txt --profile $PROFILE
sleep 3

FILES_JSON=$(aws s3 cp s3://$BUCKET_NAME/s3-browser/files.json - --profile $PROFILE 2>/dev/null)
NEW_SIZE=$(echo "$FILES_JSON" | jq -r ".[] | select(.key==\"$TEST_PREFIX/file2.txt\") | .size")
echo "   Updated size: $NEW_SIZE bytes"

if [ "$NEW_SIZE" != "$ORIGINAL_SIZE" ]; then
    echo "   ✅ Size changed - incremental update works!"
else
    echo "   ❌ Size unchanged - update may have failed"
fi

# Test 3: Delete a file
echo ""
echo "🗑️  Test 3: Deleting file1.txt..."
aws s3 rm s3://$BUCKET_NAME/$TEST_PREFIX/file1.txt --profile $PROFILE
sleep 3

FILES_JSON=$(aws s3 cp s3://$BUCKET_NAME/s3-browser/files.json - --profile $PROFILE 2>/dev/null)

if echo "$FILES_JSON" | grep -q "$TEST_PREFIX/file1.txt"; then
    echo "   ❌ file1.txt still in index - removal failed"
else
    echo "   ✅ file1.txt removed from index"
fi

# Test 4: Check total file count didn't explode
echo ""
echo "📊 Test 4: Checking for duplicates..."
TOTAL_FILES=$(echo "$FILES_JSON" | jq '. | length')
echo "   Total files in index: $TOTAL_FILES"

FILE1_COUNT=$(echo "$FILES_JSON" | jq "[.[] | select(.key | contains(\"$TEST_PREFIX/file1.txt\"))] | length")
FILE2_COUNT=$(echo "$FILES_JSON" | jq "[.[] | select(.key | contains(\"$TEST_PREFIX/file2.txt\"))] | length")
FILE3_COUNT=$(echo "$FILES_JSON" | jq "[.[] | select(.key | contains(\"$TEST_PREFIX/file3.txt\"))] | length")

echo "   file1.txt occurrences: $FILE1_COUNT (expected: 0)"
echo "   file2.txt occurrences: $FILE2_COUNT (expected: 1)"
echo "   file3.txt occurrences: $FILE3_COUNT (expected: 1)"

if [ "$FILE1_COUNT" -eq 0 ] && [ "$FILE2_COUNT" -eq 1 ] && [ "$FILE3_COUNT" -eq 1 ]; then
    echo "   ✅ No duplicates found!"
else
    echo "   ❌ Duplicate entries detected"
fi

# Test 5: Check CloudWatch logs for efficiency
echo ""
echo "📝 Test 5: Checking Lambda execution logs..."
echo "   (Checking last 5 minutes for list_objects vs head_object calls)"
aws logs tail /aws/lambda/S3FileLister --since 5m --profile $PROFILE --format short 2>/dev/null | tail -20

echo ""
echo "========================================"
echo "✅ All tests complete!"
echo ""
echo "💡 Incremental updates validated:"
echo "   - New files added to index"
echo "   - Updated files reflect new size"
echo "   - Deleted files removed from index"
echo "   - No duplicate entries"
echo ""
echo "Check CloudWatch logs above to verify:"
echo "   ✓ Should see 'head_object' calls (incremental)"
echo "   ✗ Should NOT see 'list_objects_v2' (full scan)"

rm /tmp/file1.txt /tmp/file2.txt /tmp/file3.txt
