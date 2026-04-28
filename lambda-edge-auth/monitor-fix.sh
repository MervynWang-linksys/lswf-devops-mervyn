#!/bin/bash
echo "Checking CloudFront distribution status..."
STATUS=$(aws cloudfront get-distribution --profile hn_admin --id E1TCB49P21MJOD --query 'Distribution.Status' --output text)
echo "Status: $STATUS"
echo ""

if [ "$STATUS" = "Deployed" ]; then
    echo "✅ Distribution deployed! Testing..."
    echo ""
    RESPONSE=$(curl -sI https://wiki-file.linksys.cloud/ | head -3)
    echo "$RESPONSE"
    echo ""
    
    if echo "$RESPONSE" | grep -q "302"; then
        echo "🎉 SUCCESS! Site is redirecting to login correctly!"
    elif echo "$RESPONSE" | grep -q "403"; then
        echo "⚠️  Still seeing 403 - may need a few more minutes for edge propagation"
    fi
else
    echo "⏳ Still deploying... Check again in a few minutes"
fi
