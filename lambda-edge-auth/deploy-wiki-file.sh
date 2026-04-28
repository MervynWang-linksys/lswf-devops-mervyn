#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Lambda@Edge CloudFront GitHub OAuth Deployment Script
# For wiki-file.linksys.cloud (confluence-jira-attachments bucket)
# ==============================================================================

# Configuration
AWS_PROFILE="hn_admin"
AWS_REGION="us-east-1"
DOMAIN="wiki-file.linksys.cloud"
BUCKET_NAME="confluence-jira-attachments"
ROLE_NAME="wiki-file-lambda-edge-role"
KEY_GROUP_NAME="wiki-file-auth-key-group"
PUBLIC_KEY_NAME="wiki-file-auth-public-key"
DISTRIBUTION_COMMENT="wiki-file.linksys.cloud Lambda@Edge GitHub OAuth"
SECRET_ARN="arn:aws:secretsmanager:us-east-1:400280602116:secret:prod/github/wifi_file-dZfXcv"

# Lambda function names
LAMBDA_AUTH_CHECK="wiki-file-auth-check"
LAMBDA_AUTH_APP="wiki-file-auth-app"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Status helpers
info()    { echo -e "${BLUE}ℹ${NC} $1"; }
success() { echo -e "${GREEN}✓${NC} $1"; }
warn()    { echo -e "${YELLOW}…${NC} $1"; }
error()   { echo -e "${RED}✗${NC} $1"; }
fail()    { error "$1"; exit 1; }

# AWS CLI wrapper
aws_cmd() {
    aws --profile "$AWS_PROFILE" --region "$AWS_REGION" "$@"
}

# ==============================================================================
# Retrieve GitHub OAuth Config from Secrets Manager
# ==============================================================================
fetch_github_config() {
    info "Fetching GitHub OAuth config from Secrets Manager..."
    
    SECRET_JSON=$(aws_cmd secretsmanager get-secret-value \
        --secret-id "$SECRET_ARN" \
        --query 'SecretString' \
        --output text)
    
    GITHUB_CLIENT_ID=$(echo "$SECRET_JSON" | jq -r '.id')
    GITHUB_CLIENT_SECRET=$(echo "$SECRET_JSON" | jq -r '.key')
    GITHUB_ORG=$(echo "$SECRET_JSON" | jq -r '.org')
    
    if [[ -z "$GITHUB_CLIENT_ID" || "$GITHUB_CLIENT_ID" == "null" ]]; then
        fail "Failed to retrieve GitHub client ID from secret"
    fi
    
    if [[ -z "$GITHUB_CLIENT_SECRET" || "$GITHUB_CLIENT_SECRET" == "null" ]]; then
        fail "Failed to retrieve GitHub client secret from secret"
    fi
    
    if [[ -z "$GITHUB_ORG" || "$GITHUB_ORG" == "null" ]]; then
        fail "Failed to retrieve GitHub org from secret"
    fi
    
    success "Retrieved GitHub OAuth config: client_id=${GITHUB_CLIENT_ID:0:8}..., org=$GITHUB_ORG"
}

# ==============================================================================
# IAM Role
# ==============================================================================
create_iam_role() {
    info "Checking IAM role: $ROLE_NAME"

    if aws_cmd iam get-role --role-name "$ROLE_NAME" &>/dev/null; then
        success "IAM role already exists: $ROLE_NAME"
        ROLE_ARN=$(aws_cmd iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)
    else
        warn "Creating IAM role: $ROLE_NAME"

        TRUST_POLICY=$(cat <<'EOF'
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": [
                    "lambda.amazonaws.com",
                    "edgelambda.amazonaws.com"
                ]
            },
            "Action": "sts:AssumeRole"
        }
    ]
}
EOF
)
        ROLE_ARN=$(aws_cmd iam create-role \
            --role-name "$ROLE_NAME" \
            --assume-role-policy-document "$TRUST_POLICY" \
            --query 'Role.Arn' \
            --output text)

        aws_cmd iam attach-role-policy \
            --role-name "$ROLE_NAME" \
            --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"

        success "Created IAM role: $ROLE_ARN"

        info "Waiting for IAM role to propagate..."
        sleep 10
    fi
}

# ==============================================================================
# RSA Key Pair for CloudFront Signed Cookies
# ==============================================================================
generate_key_pair() {
    info "Checking RSA key pair for signed cookies"

    mkdir -p keys

    if [[ -f "keys/private_key.pem" ]]; then
        success "Private key already exists: keys/private_key.pem"
    else
        warn "Generating RSA-2048 key pair"
        openssl genrsa -out keys/private_key.pem 2048 2>/dev/null
        openssl rsa -in keys/private_key.pem -pubout -out keys/public_key.pem 2>/dev/null
        chmod 600 keys/private_key.pem
        success "Generated key pair in keys/"
    fi

    # Generate public key if missing
    if [[ ! -f "keys/public_key.pem" ]]; then
        openssl rsa -in keys/private_key.pem -pubout -out keys/public_key.pem 2>/dev/null
    fi

    PRIVATE_KEY_PEM=$(awk '{printf "%s\\n", $0}' keys/private_key.pem)
}

# ==============================================================================
# CloudFront Public Key and Key Group
# ==============================================================================
create_cloudfront_key_group() {
    info "Checking CloudFront public key: $PUBLIC_KEY_NAME"

    # Check if public key exists
    PUBLIC_KEY_ID=$(aws_cmd cloudfront list-public-keys \
        --query "PublicKeyList.Items[?Name=='$PUBLIC_KEY_NAME'].Id" \
        --output text 2>/dev/null || echo "")

    if [[ -n "$PUBLIC_KEY_ID" && "$PUBLIC_KEY_ID" != "None" ]]; then
        success "CloudFront public key already exists: $PUBLIC_KEY_ID"
    else
        warn "Creating CloudFront public key: $PUBLIC_KEY_NAME"

        PUBLIC_KEY_ENCODED=$(cat keys/public_key.pem)
        CALLER_REF="key-$(date +%s)"

        PUBLIC_KEY_ID=$(aws_cmd cloudfront create-public-key \
            --public-key-config "{
                \"CallerReference\": \"$CALLER_REF\",
                \"Name\": \"$PUBLIC_KEY_NAME\",
                \"EncodedKey\": $(echo "$PUBLIC_KEY_ENCODED" | jq -Rs .)
            }" \
            --query 'PublicKey.Id' \
            --output text)

        success "Created CloudFront public key: $PUBLIC_KEY_ID"
    fi

    # Check if key group exists
    info "Checking CloudFront key group: $KEY_GROUP_NAME"

    KEY_GROUP_ID=$(aws_cmd cloudfront list-key-groups \
        --query "KeyGroupList.Items[?KeyGroup.KeyGroupConfig.Name=='$KEY_GROUP_NAME'].KeyGroup.Id" \
        --output text 2>/dev/null || echo "")

    if [[ -n "$KEY_GROUP_ID" && "$KEY_GROUP_ID" != "None" ]]; then
        success "CloudFront key group already exists: $KEY_GROUP_ID"
    else
        warn "Creating CloudFront key group: $KEY_GROUP_NAME"

        CALLER_REF="keygroup-$(date +%s)"

        KEY_GROUP_ID=$(aws_cmd cloudfront create-key-group \
            --key-group-config "{
                \"Name\": \"$KEY_GROUP_NAME\",
                \"Items\": [\"$PUBLIC_KEY_ID\"]
            }" \
            --query 'KeyGroup.Id' \
            --output text)

        success "Created CloudFront key group: $KEY_GROUP_ID"
    fi
}

# ==============================================================================
# Verify S3 Bucket Exists
# ==============================================================================
verify_s3_bucket() {
    info "Verifying S3 bucket exists: $BUCKET_NAME"

    if aws_cmd s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
        success "S3 bucket exists: $BUCKET_NAME"
        
        # Get the bucket's actual region
        BUCKET_REGION=$(aws_cmd s3api get-bucket-location --bucket "$BUCKET_NAME" --output text)
        if [[ "$BUCKET_REGION" == "None" ]]; then
            BUCKET_REGION="us-east-1"  # us-east-1 returns "None"
        fi
        
        info "Bucket region detected: $BUCKET_REGION"
        AWS_REGION="$BUCKET_REGION"  # Update AWS_REGION to match bucket
    else
        fail "S3 bucket does not exist: $BUCKET_NAME. Please create it first."
    fi
}

# ==============================================================================
# Lambda Functions
# ==============================================================================
package_lambda() {
    local name="$1"
    local source="$2"
    local zipfile="$3"

    info "Packaging Lambda: $name"

    # Create zip with proper structure
    if [[ "$source" == "src/app.js" ]]; then
        # Generate config.json for app Lambda
        info "Generating config.json for app Lambda"
        cat > src/config.json <<EOF
{
    "clientId": "$GITHUB_CLIENT_ID",
    "clientSecret": "$GITHUB_CLIENT_SECRET",
    "githubOrg": "$GITHUB_ORG",
    "cloudfrontDomain": "$DOMAIN",
    "cloudfrontKeyId": "$PUBLIC_KEY_ID",
    "privateKeyPem": $(jq -Rs . keys/private_key.pem)
}
EOF
        # For app.js, we need to package it at the root of the zip along with config.json
        (cd src && zip -j "../$zipfile" app.js config.json) >/dev/null
    else
        zip -j "$zipfile" "$source" >/dev/null
    fi

    success "Packaged: $zipfile"
}

create_or_update_lambda() {
    local name="$1"
    local zipfile="$2"
    local handler="$3"

    info "Checking Lambda function: $name"

    if aws_cmd lambda get-function --function-name "$name" &>/dev/null; then
        success "Lambda function exists: $name"
        warn "Updating Lambda function code: $name"

        aws_cmd lambda update-function-code \
            --function-name "$name" \
            --zip-file "fileb://$zipfile" \
            --output text >/dev/null

        # Wait for update to complete
        aws_cmd lambda wait function-updated --function-name "$name"

        # Publish new version
        VERSION_ARN=$(aws_cmd lambda publish-version \
            --function-name "$name" \
            --query 'FunctionArn' \
            --output text)

        success "Updated and published version: $name"
    else
        warn "Creating Lambda function: $name"

        FUNCTION_ARN=$(aws_cmd lambda create-function \
            --function-name "$name" \
            --runtime nodejs22.x \
            --role "$ROLE_ARN" \
            --handler "$handler" \
            --zip-file "fileb://$zipfile" \
            --timeout 5 \
            --memory-size 128 \
            --query 'FunctionArn' \
            --output text)

        # Wait for function to be active
        aws_cmd lambda wait function-active --function-name "$name"

        # Publish version (required for Lambda@Edge)
        VERSION_ARN=$(aws_cmd lambda publish-version \
            --function-name "$name" \
            --query 'FunctionArn' \
            --output text)

        success "Created Lambda function: $VERSION_ARN"
    fi

    echo "$VERSION_ARN"
}

deploy_lambdas() {
    info "Deploying Lambda functions..."
    echo ""

    # Package lambdas
    package_lambda "$LAMBDA_AUTH_CHECK" "auth-check.js" "auth-check.zip"
    package_lambda "$LAMBDA_AUTH_APP" "src/app.js" "app.zip"

    echo ""

    # Create/update lambdas and capture version ARNs
    AUTH_CHECK_VERSION_ARN=$(create_or_update_lambda "$LAMBDA_AUTH_CHECK" "auth-check.zip" "auth-check.handler" 2>&1 | tail -1)
    AUTH_APP_VERSION_ARN=$(create_or_update_lambda "$LAMBDA_AUTH_APP" "app.zip" "app.handler" 2>&1 | tail -1)

    # Cleanup zip files
    rm -f auth-check.zip app.zip

    echo ""
    info "Lambda ARNs captured:"
    info "  auth-check: $AUTH_CHECK_VERSION_ARN"
    info "  auth-app: $AUTH_APP_VERSION_ARN"
    echo ""
}

# ==============================================================================
# CloudFront Origin Access Control
# ==============================================================================
create_oac() {
    info "Checking CloudFront Origin Access Control"

    OAC_NAME="$BUCKET_NAME-oac"

    OAC_ID=$(aws_cmd cloudfront list-origin-access-controls \
        --query "OriginAccessControlList.Items[?Name=='$OAC_NAME'].Id" \
        --output text 2>/dev/null || echo "")

    if [[ -n "$OAC_ID" && "$OAC_ID" != "None" ]]; then
        success "OAC already exists: $OAC_ID"
    else
        warn "Creating Origin Access Control: $OAC_NAME"

        OAC_ID=$(aws_cmd cloudfront create-origin-access-control \
            --origin-access-control-config "{
                \"Name\": \"$OAC_NAME\",
                \"Description\": \"OAC for $BUCKET_NAME\",
                \"SigningProtocol\": \"sigv4\",
                \"SigningBehavior\": \"always\",
                \"OriginAccessControlOriginType\": \"s3\"
            }" \
            --query 'OriginAccessControl.Id' \
            --output text)

        success "Created OAC: $OAC_ID"
    fi
}

# ==============================================================================
# CloudFront Distribution
# ==============================================================================
create_cloudfront_distribution() {
    info "Checking CloudFront distribution for $DOMAIN"

    # Check if distribution exists by alias
    DISTRIBUTION_ID=$(aws_cmd cloudfront list-distributions \
        --query "DistributionList.Items[?Aliases.Items && contains(Aliases.Items, '$DOMAIN')].Id" \
        --output text 2>/dev/null || echo "")

    if [[ -n "$DISTRIBUTION_ID" && "$DISTRIBUTION_ID" != "None" ]]; then
        success "CloudFront distribution already exists: $DISTRIBUTION_ID"
        DISTRIBUTION_DOMAIN=$(aws_cmd cloudfront get-distribution \
            --id "$DISTRIBUTION_ID" \
            --query 'Distribution.DomainName' \
            --output text)
        return
    fi

    warn "Creating CloudFront distribution..."

    # Get AWS account ID for bucket policy
    ACCOUNT_ID=$(aws_cmd sts get-caller-identity --query 'Account' --output text)

    # Get ACM certificate
    info "Looking up ACM certificate for $DOMAIN"
    ACM_CERT_ARN=$(get_acm_certificate)
    
    if [[ -z "$ACM_CERT_ARN" ]]; then
        error "No ACM certificate found for $DOMAIN or *.linksys.cloud"
        error "Please create an ACM certificate in us-east-1 first"
        fail "ACM certificate required for custom domain"
    fi
    
    success "Found ACM certificate: $ACM_CERT_ARN"

    CALLER_REF="dist-$(date +%s)"
    ORIGIN_ID="S3-$BUCKET_NAME"

    # Create distribution config
    DIST_CONFIG=$(cat <<EOF
{
    "CallerReference": "$CALLER_REF",
    "Comment": "$DISTRIBUTION_COMMENT",
    "Enabled": true,
    "Aliases": {
        "Quantity": 1,
        "Items": ["$DOMAIN"]
    },
    "Origins": {
        "Quantity": 1,
        "Items": [
            {
                "Id": "$ORIGIN_ID",
                "DomainName": "$BUCKET_NAME.s3.$AWS_REGION.amazonaws.com",
                "OriginAccessControlId": "$OAC_ID",
                "S3OriginConfig": {
                    "OriginAccessIdentity": ""
                }
            }
        ]
    },
    "DefaultCacheBehavior": {
        "TargetOriginId": "$ORIGIN_ID",
        "ViewerProtocolPolicy": "redirect-to-https",
        "AllowedMethods": {
            "Quantity": 2,
            "Items": ["GET", "HEAD"],
            "CachedMethods": {
                "Quantity": 2,
                "Items": ["GET", "HEAD"]
            }
        },
        "CachePolicyId": "658327ea-f89d-4fab-a63d-7e88639e58f6",
        "Compress": true,
        "LambdaFunctionAssociations": {
            "Quantity": 1,
            "Items": [
                {
                    "LambdaFunctionARN": "$AUTH_CHECK_VERSION_ARN",
                    "EventType": "viewer-request",
                    "IncludeBody": false
                }
            ]
        }
    },
    "CacheBehaviors": {
        "Quantity": 2,
        "Items": [
            {
                "PathPattern": "/callback",
                "TargetOriginId": "$ORIGIN_ID",
                "ViewerProtocolPolicy": "redirect-to-https",
                "AllowedMethods": {
                    "Quantity": 2,
                    "Items": ["GET", "HEAD"],
                    "CachedMethods": {
                        "Quantity": 2,
                        "Items": ["GET", "HEAD"]
                    }
                },
                "CachePolicyId": "4135ea2d-6df8-44a3-9df3-4b5a84be39ad",
                "Compress": true,
                "LambdaFunctionAssociations": {
                    "Quantity": 1,
                    "Items": [
                        {
                            "LambdaFunctionARN": "$AUTH_APP_VERSION_ARN",
                            "EventType": "viewer-request",
                            "IncludeBody": false
                        }
                    ]
                }
            },
            {
                "PathPattern": "/login",
                "TargetOriginId": "$ORIGIN_ID",
                "ViewerProtocolPolicy": "redirect-to-https",
                "AllowedMethods": {
                    "Quantity": 2,
                    "Items": ["GET", "HEAD"],
                    "CachedMethods": {
                        "Quantity": 2,
                        "Items": ["GET", "HEAD"]
                    }
                },
                "CachePolicyId": "4135ea2d-6df8-44a3-9df3-4b5a84be39ad",
                "Compress": true,
                "LambdaFunctionAssociations": {
                    "Quantity": 1,
                    "Items": [
                        {
                            "LambdaFunctionARN": "$AUTH_APP_VERSION_ARN",
                            "EventType": "viewer-request",
                            "IncludeBody": false
                        }
                    ]
                }
            }
        ]
    },
    "ViewerCertificate": {
        "CloudFrontDefaultCertificate": false,
        "ACMCertificateArn": "$ACM_CERT_ARN",
        "SSLSupportMethod": "sni-only",
        "MinimumProtocolVersion": "TLSv1.2_2021"
    }
}
EOF
)

    DISTRIBUTION_ID=$(aws_cmd cloudfront create-distribution \
        --distribution-config "$DIST_CONFIG" \
        --query 'Distribution.Id' \
        --output text)

    DISTRIBUTION_DOMAIN=$(aws_cmd cloudfront get-distribution \
        --id "$DISTRIBUTION_ID" \
        --query 'Distribution.DomainName' \
        --output text)

    success "Created CloudFront distribution: $DISTRIBUTION_ID"
    info "CloudFront domain: $DISTRIBUTION_DOMAIN"

    # Update bucket policy to allow OAC
    update_bucket_policy
}

# ==============================================================================
# ACM Certificate Lookup
# ==============================================================================
get_acm_certificate() {
    # Try wildcard cert first (silently)
    CERT_ARN=$(aws_cmd acm list-certificates \
        --query "CertificateSummaryList[?DomainName=='*.linksys.cloud'].CertificateArn" \
        --output text 2>/dev/null | head -1 || echo "")
    
    if [[ -z "$CERT_ARN" || "$CERT_ARN" == "None" ]]; then
        # Try exact domain match
        CERT_ARN=$(aws_cmd acm list-certificates \
            --query "CertificateSummaryList[?DomainName=='$DOMAIN'].CertificateArn" \
            --output text 2>/dev/null | head -1 || echo "")
    fi
    
    if [[ -z "$CERT_ARN" || "$CERT_ARN" == "None" ]]; then
        echo ""
    else
        echo "$CERT_ARN"
    fi
}

# ==============================================================================
# S3 Bucket Policy for OAC
# ==============================================================================
update_bucket_policy() {
    info "Updating S3 bucket policy for OAC access"

    ACCOUNT_ID=$(aws_cmd sts get-caller-identity --query 'Account' --output text)

    BUCKET_POLICY=$(cat <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "AllowCloudFrontServicePrincipal",
            "Effect": "Allow",
            "Principal": {
                "Service": "cloudfront.amazonaws.com"
            },
            "Action": "s3:GetObject",
            "Resource": "arn:aws:s3:::$BUCKET_NAME/*",
            "Condition": {
                "StringEquals": {
                    "AWS:SourceArn": "arn:aws:cloudfront::$ACCOUNT_ID:distribution/$DISTRIBUTION_ID"
                }
            }
        }
    ]
}
EOF
)

    aws_cmd s3api put-bucket-policy \
        --bucket "$BUCKET_NAME" \
        --policy "$BUCKET_POLICY"

    success "Updated bucket policy for CloudFront OAC access"
}

# ==============================================================================
# Main Deployment Flow
# ==============================================================================
main() {
    echo ""
    info "======================================================================"
    info "Lambda@Edge GitHub OAuth Deployment for $DOMAIN"
    info "======================================================================"
    echo ""

    fetch_github_config
    verify_s3_bucket
    create_iam_role
    generate_key_pair
    create_cloudfront_key_group
    deploy_lambdas
    create_oac
    create_cloudfront_distribution

    echo ""
    success "======================================================================"
    success "Deployment Complete!"
    success "======================================================================"
    echo ""
    info "CloudFront Distribution: $DISTRIBUTION_ID"
    info "CloudFront Domain: $DISTRIBUTION_DOMAIN"
    info "Custom Domain: $DOMAIN"
    echo ""
    info "Next steps:"
    info "  1. Create DNS CNAME record: $DOMAIN -> $DISTRIBUTION_DOMAIN"
    info "  2. Wait for CloudFront distribution to deploy (~15-20 minutes)"
    info "  3. Test: https://$DOMAIN/"
    echo ""
    info "GitHub OAuth callback URL: https://$DOMAIN/callback"
    info "Make sure this is configured in your GitHub OAuth app"
    echo ""
}

main "$@"
