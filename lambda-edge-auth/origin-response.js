'use strict';

/**
 * Lambda@Edge Origin Response handler for 404 redirects.
 * Redirects 404 errors to /index.html for better UX.
 */

exports.handler = async (event) => {
    const response = event.Records[0].cf.response;
    const request = event.Records[0].cf.request;
    
    // Handle directory index for /s3-browser
    if (request.uri === '/s3-browser' || request.uri === '/s3-browser/') {
        return {
            status: '302',
            statusDescription: 'Found',
            headers: {
                location: [{
                    key: 'Location',
                    value: '/s3-browser/index.html'
                }],
                'cache-control': [{
                    key: 'Cache-Control',
                    value: 'no-cache, no-store, must-revalidate'
                }]
            }
        };
    }
    
    // If response is 404 or 403, redirect to root index.html
    if (response.status === '404' || response.status === '403') {
        // Don't redirect if already requesting index.html to avoid loops
        if (request.uri === '/index.html' || request.uri === '/' || request.uri.endsWith('/index.html')) {
            return response;
        }
        
        return {
            status: '302',
            statusDescription: 'Found',
            headers: {
                location: [{
                    key: 'Location',
                    value: '/index.html'
                }],
                'cache-control': [{
                    key: 'Cache-Control',
                    value: 'no-cache, no-store, must-revalidate'
                }]
            }
        };
    }
    
    return response;
};
