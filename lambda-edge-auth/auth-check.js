'use strict';

/**
 * Lambda@Edge Viewer Request handler for authentication check.
 * Simpler approach: use session token cookie instead of CloudFront signed cookies.
 */

const crypto = require('node:crypto');

let cfg;
try {
    cfg = require('./config.json');
} catch (e) {
    cfg = global.__CONFIG__ || {};
}

function parseCookies(cookieHeader) {
    if (!cookieHeader) return {};
    return Object.fromEntries(
        cookieHeader.split(';').map(c => {
            const [key, ...val] = c.trim().split('=');
            return [key, val.join('=')];
        })
    );
}

function verifySessionToken(token) {
    if (!token || !cfg.sessionSecret) return false;
    
    try {
        // Session token format: timestamp.signature
        const [timestamp, signature] = token.split('.');
        if (!timestamp || !signature) return false;
        
        // Check if expired (24 hours)
        const tokenTime = parseInt(timestamp, 10);
        const now = Date.now();
        if (now - tokenTime > 86400000) return false;
        
        // Verify signature
        const hmac = crypto.createHmac('sha256', cfg.sessionSecret);
        hmac.update(timestamp);
        const expectedSig = hmac.digest('hex');
        
        return signature === expectedSig;
    } catch (err) {
        console.error('Session verification error:', err);
        return false;
    }
}

exports.handler = async (event) => {
    const request = event.Records[0].cf.request;
    const headers = request.headers;
    
    // Skip auth for login and callback paths
    if (request.uri === '/login' || request.uri === '/callback') {
        return request;
    }
    
    // Check for session cookie
    const cookieHeader = headers.cookie?.[0]?.value;
    const cookies = parseCookies(cookieHeader);
    const sessionToken = cookies['wiki-file-session'];
    
    if (verifySessionToken(sessionToken)) {
        // Valid session - allow request to proceed
        return request;
    }
    
    // No valid session - redirect to login
    const host = headers.host?.[0]?.value || cfg.cloudfrontDomain;
    return {
        status: '302',
        statusDescription: 'Found',
        headers: {
            location: [{ 
                key: 'Location', 
                value: `https://${host}/login?return=${encodeURIComponent(request.uri)}`
            }],
            'cache-control': [{ 
                key: 'Cache-Control', 
                value: 'no-cache, no-store, must-revalidate' 
            }]
        },
    };
};
