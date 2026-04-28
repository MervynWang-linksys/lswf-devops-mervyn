# CloudFront GitHub OAuth Access Control Implementation Plan

## Overview

This project implements a secure access control mechanism for AWS CloudFront using GitHub OAuth. Users authenticate via GitHub, and upon successful organization membership verification, they receive a CloudFront Signed Cookie, granting them access to the protected content.

## Architecture

1. **CloudFront**: Configured to require Signed Cookies.
2. **Lambda@Edge (Node.js 22.x)**:
   - `auth-check.js`: Viewer Request handler - validates session, redirects unauthenticated users to GitHub OAuth
   - `auth-callback.js`: Viewer Request handler - processes OAuth callback, verifies organization membership, sets session cookie
3. **API Gateway Lambda (Node.js 22.x)**:
   - `src/app.js`: Full OAuth flow with CloudFront Signed Cookie generation
4. **AWS Systems Manager (Parameter Store)**: Stores sensitive configuration (GitHub Client ID/Secret, CloudFront private key)

## Implementation Details

### Lambda@Edge Functions

- **Runtime**: Node.js 22.x (`nodejs22.x`)
- **Dependencies**: None (uses native Node.js APIs)
- **HTTP Client**: Native `fetch()` API
- **Cookie Handling**: Custom lightweight implementation (no external dependencies)
- **Crypto Operations**: `node:crypto` module for CloudFront Signed Cookie generation

### Node.js 22.x Features

- Native `fetch()` for HTTP requests (replaces axios/node-fetch)
- `Object.hasOwn()` for safe property checking
- Optional chaining (`?.`) and nullish coalescing (`??`)
- `node:` protocol for built-in module imports

## Deliverables

- `auth-check.js`: Lambda@Edge viewer request authentication check
- `auth-callback.js`: Lambda@Edge OAuth callback handler
- `src/app.js`: API Gateway Lambda handler with full OAuth flow
- `package.json`: Project configuration (Node.js 22.x engine requirement)
- `README.md`: Setup and deployment guide
- `implementation_plan.md`: This document

## Security Considerations

- All cookies use `HttpOnly`, `Secure`, and `SameSite=Lax` attributes
- Sensitive credentials stored in AWS SSM Parameter Store
- CloudFront Signed Cookies use RSA-SHA1 signatures
- Organization membership verified before granting access
