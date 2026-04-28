# CloudFront GitHub OAuth Access Control Setup Guide

## Overview

This project implements secure access control for AWS CloudFront using GitHub OAuth. Users authenticate via GitHub, and upon successful organization membership verification, they receive CloudFront Signed Cookies granting access to protected content.

## Requirements

- **Node.js 22.x** (Lambda runtime: `nodejs22.x`)
- AWS CLI and AWS SAM CLI installed
- GitHub OAuth App created
- CloudFront Key Pair generated (Public Key in AWS, Private Key stored in SSM)

## Architecture

1. **CloudFront**: Configured to require Signed Cookies
2. **Lambda@Edge Functions**:
   - `auth-check.js`: Viewer Request - checks for valid session, redirects to GitHub OAuth if not authenticated
   - `auth-callback.js`: Viewer Request - handles OAuth callback, verifies org membership, sets session cookie
3. **API Gateway Lambda** (optional):
   - `src/app.js`: Full OAuth flow with CloudFront Signed Cookie generation

## Setup

### 1. GitHub OAuth App

- Create a new OAuth App at https://github.com/settings/developers
- Set callback URL to your API Gateway endpoint (e.g., `https://your-api.execute-api.region.amazonaws.com/callback`)
- Note the Client ID and Client Secret

### 2. SSM Parameters

Store sensitive configuration in AWS Systems Manager Parameter Store:

```bash
aws ssm put-parameter --name "/oauth/github/client_id" --value "your_client_id" --type SecureString
aws ssm put-parameter --name "/oauth/github/client_secret" --value "your_secret" --type SecureString
aws ssm put-parameter --name "/oauth/github/org" --value "your_org_name" --type SecureString
aws ssm put-parameter --name "/oauth/cloudfront/private_key" --value "file://private_key.pem" --type SecureString
aws ssm put-parameter --name "/oauth/cloudfront/key_id" --value "your_key_pair_id" --type SecureString
```

### 3. Environment Variables

The Lambda functions require these environment variables:

**Lambda@Edge (`auth-check.js`, `auth-callback.js`)**:
- `CLIENT_ID`: GitHub OAuth App Client ID
- `CLIENT_SECRET`: GitHub OAuth App Client Secret
- `GITHUB_ORG`: Required GitHub organization for access

**API Gateway Lambda (`src/app.js`)**:
- `GITHUB_CLIENT_ID`: GitHub OAuth App Client ID
- `GITHUB_CLIENT_SECRET`: GitHub OAuth App Client Secret
- `GITHUB_ORG`: Required GitHub organization for access
- `CLOUDFRONT_DOMAIN`: Your CloudFront distribution domain
- `CLOUDFRONT_KEY_ID`: CloudFront Key Pair ID
- `PRIVATE_KEY_PEM`: RSA private key for signing cookies

### 4. Deployment

```bash
sam build
sam deploy --guided
```

## Lambda@Edge Configuration

When attaching Lambda@Edge functions to CloudFront:

- **auth-check.js**: Attach to Viewer Request event
- **auth-callback.js**: Attach to Viewer Request event for `/callback` path pattern

## Node.js 22.x Features Used

This project uses modern Node.js 22.x features:

- **Native `fetch()`**: No external HTTP libraries needed (axios, node-fetch)
- **`Object.hasOwn()`**: Safe property checking
- **Optional chaining (`?.`)**: Safe property access
- **Nullish coalescing (`??`)**: Default value handling
- **`node:crypto`** module: Native cryptographic operations for CloudFront Signed Cookies

## Security Notes

- All cookies are set with `HttpOnly`, `Secure`, and `SameSite=Lax` attributes
- Session validation should be enhanced for production (JWT verification, session store)
- Private keys should never be committed to source control
- Use AWS Secrets Manager or SSM Parameter Store for sensitive values

## License

MIT
