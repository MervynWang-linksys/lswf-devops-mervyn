'use strict';

/**
 * Lambda@Edge Origin Response handler for 404 redirects.
 * Redirects 404 errors to /index.html for better UX.
 */

exports.handler = async (event) => {
    const response = event.Records[0].cf.response;
    const request = event.Records[0].cf.request;
    
    // If response is 404 or 403, redirect to index.html
    if (response.status === '404' || response.status === '403') {
        // Don't redirect if already requesting index.html to avoid loops
        if (request.uri === '/index.html' || request.uri === '/') {
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
