'use strict';

/**
 * Lambda@Edge Viewer Request handler for authentication check.
 * Node.js 22.x runtime - uses native APIs.
 *
 * This function checks for the CloudFront Signed Cookie (CloudFront-Signature).
 * If missing, it redirects to the /login path handled by our OAuth app lambda.
 */

exports.handler = async (event) => {
    const request = event.Records[0].cf.request;
    const headers = request.headers;

    // Exclude login and callback paths from auth check
    // (though they should have their own Cache Behaviors mapping to app.js anyway)
    if (request.uri === '/login' || request.uri === '/callback') {
        return request;
    }

    const cookieHeader = headers.cookie?.[0]?.value ?? '';
    
    // Check for CloudFront Signed Cookie
    // When signed cookies are used, CloudFront requires three cookies:
    // CloudFront-Policy, CloudFront-Signature, and CloudFront-Key-Pair-Id.
    const hasSignedCookie = cookieHeader.includes('CloudFront-Signature=');

    if (hasSignedCookie) {
        // User is authenticated, allow the request to proceed.
        // CloudFront will then natively validate the signed cookies.
        return request;
    }

    // Not logged in - redirect to our OAuth login handler
    return {
        status: '302',
        statusDescription: 'Found',
        headers: {
            location: [{ key: 'Location', value: '/login' }],
            'cache-control': [{ key: 'Cache-Control', value: 'no-cache, no-store, must-revalidate' }]
        },
    };
};
