#!/bin/bash
set -e

FUNCTION_NAME="S3FileLister"
BUCKET_NAME="fw-qa-internal-lswf"
PROFILE="hn_mervyn"
REGION="us-east-1"
ROLE_ARN="arn:aws:iam::400280602116:role/S3FileListerRole"

WORKDIR="/home/mervyn/work"

echo "1. 壓縮 Lambda 程式碼..."
zip -j lambda.zip $WORKDIR/s3-browser-system/lambda/index.py

echo "2. 建立 Lambda 函式..."
aws lambda create-function \
    --function-name $FUNCTION_NAME \
    --runtime python3.9 \
    --role $ROLE_ARN \
    --handler index.lambda_handler \
    --zip-file fileb://lambda.zip \
    --environment Variables="{BUCKET_NAME=$BUCKET_NAME}" \
    --profile $PROFILE \
    --region $REGION

echo "3. 賦予 S3 觸發 Lambda 的權限..."
aws lambda add-permission \
    --function-name $FUNCTION_NAME \
    --statement-id s3-trigger-permission \
    --action "lambda:InvokeFunction" \
    --principal s3.amazonaws.com \
    --source-arn arn:aws:s3:::$BUCKET_NAME \
    --profile $PROFILE

echo "4. 設定 S3 事件通知..."
# 為了避免移除現有通知，這裡先取得既有配置，若無則建立新配置
aws s3api put-bucket-notification-configuration \
    --bucket $BUCKET_NAME \
    --notification-configuration "{
        \"LambdaFunctionConfigurations\": [{
            \"LambdaFunctionArn\": \"$(aws lambda get-function --function-name $FUNCTION_NAME --profile $PROFILE --query 'Configuration.FunctionArn' --output text)\",
            \"Events\": [\"s3:ObjectCreated:*\", \"s3:ObjectRemoved:*\"]
        }]
    }" \
    --profile $PROFILE

echo "5. 上傳前端..."
aws s3 cp $WORKDIR/s3-browser-system/frontend/index.html s3://$BUCKET_NAME/s3-browser/index.html --profile $PROFILE

echo "6. 觸發初始掃描 (建立 files.json)..."
# Create a dummy file to trigger Lambda for initial scan
echo '{"trigger":"initial-scan"}' > /tmp/trigger.json
aws s3 cp /tmp/trigger.json s3://$BUCKET_NAME/.s3-browser-trigger --profile $PROFILE
rm /tmp/trigger.json

echo "7. 等待 Lambda 執行..."
sleep 5

echo "8. 清理觸發檔案..."
aws s3 rm s3://$BUCKET_NAME/.s3-browser-trigger --profile $PROFILE

echo "✅ 部署完成！"
echo "📁 前端: https://$BUCKET_NAME.s3.amazonaws.com/s3-browser/index.html"
echo "📄 檔案清單: https://$BUCKET_NAME.s3.amazonaws.com/s3-browser/files.json"
rm lambda.zip
