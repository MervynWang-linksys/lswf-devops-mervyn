#!/bin/bash
DIST_ID="E1TCB49P21MJOD"
STATUS=$(aws cloudfront get-distribution --profile hn_admin --id $DIST_ID --query 'Distribution.Status' --output text)
echo "CloudFront Distribution Status: $STATUS"

if [ "$STATUS" = "Deployed" ]; then
    echo "✅ Distribution is ready!"
    echo ""
    echo "Test URL: https://wiki-file.linksys.cloud/"
    echo ""
    echo "Expected flow:"
    echo "1. Visit https://wiki-file.linksys.cloud/"
    echo "2. Redirected to GitHub OAuth"
    echo "3. Authorize with linksys org membership"
    echo "4. Redirected back with signed cookies"
    echo "5. Access granted to S3 files"
else
    echo "⏳ Still deploying... Check again in a few minutes."
fi
