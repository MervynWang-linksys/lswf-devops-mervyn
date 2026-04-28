'use strict';

/**
 * Lambda@Edge Viewer Request handler for OAuth flow.
 * Node.js 22.x runtime - uses native fetch() and crypto.
 *
 * Handles /login and /callback routes for GitHub OAuth with
 * CloudFront Signed Cookie generation.
 *
 * Configuration is injected via config.json during deployment.
 */

const crypto = require('node:crypto');

let cfg;
try {
    cfg = require('./config.json');
} catch (e) {
    // Graceful fallback for local development or testing without config
    cfg = global.__CONFIG__ || {};
}

function createSignedCookiePolicy(domain, expiresMs) {
    const policy = {
        Statement: [{
            Resource: `https://${domain}/*`,
            Condition: {
                DateLessThan: {
                    'AWS:EpochTime': Math.floor(expiresMs / 1000),
                },
            },
        }],
    };
    return JSON.stringify(policy);
}

function signPolicy(policy, privateKeyPem) {
    const sign = crypto.createSign('RSA-SHA256');
    sign.update(policy);
    const signature = sign.sign(privateKeyPem, 'base64');
    return signature
        .replace(/\+/g, '-')
        .replace(/=/g, '_')
        .replace(/\//g, '~');
}

function toUrlSafeBase64(str) {
    return Buffer.from(str)
        .toString('base64')
        .replace(/\+/g, '-')
        .replace(/=/g, '_')
        .replace(/\//g, '~');
}

function generateSignedCookies(domain, keyId, privateKeyPem, ttlMs = 24 * 60 * 60 * 1000) {
    const expiresMs = Date.now() + ttlMs;
    const policy = createSignedCookiePolicy(domain, expiresMs);
    const signature = signPolicy(policy, privateKeyPem);
    const encodedPolicy = toUrlSafeBase64(policy);

    return {
        'CloudFront-Policy': encodedPolicy,
        'CloudFront-Signature': signature,
        'CloudFront-Key-Pair-Id': keyId,
    };
}

function serializeCookie(name, value, options = {}) {
    const parts = [`${encodeURIComponent(name)}=${encodeURIComponent(value)}`];
    if (options.domain) parts.push(`Domain=${options.domain}`);
    if (options.path) parts.push(`Path=${options.path}`);
    if (options.httpOnly) parts.push('HttpOnly');
    if (options.secure) parts.push('Secure');
    if (options.sameSite) parts.push(`SameSite=${options.sameSite}`);
    if (options.maxAge) parts.push(`Max-Age=${options.maxAge}`);
    return parts.join('; ');
}

function login(request) {
    const host = request.headers.host?.[0]?.value || cfg.cloudfrontDomain;
    const redirectUri = `https://${host}/callback`;
    const authUrl = `https://github.com/login/oauth/authorize?client_id=${cfg.clientId}&redirect_uri=${encodeURIComponent(redirectUri)}&scope=read:org`;

    return {
        status: '302',
        statusDescription: 'Found',
        headers: {
            location: [{ key: 'Location', value: authUrl }],
            'cache-control': [{ key: 'Cache-Control', value: 'no-cache, no-store, must-revalidate' }]
        },
    };
}

async function callback(request) {
    const params = new URLSearchParams(request.querystring);
    const code = params.get('code');

    if (!code) {
        return {
            status: '400',
            statusDescription: 'Bad Request',
            body: 'Missing authorization code',
        };
    }

    try {
        const tokenResponse = await fetch('https://github.com/login/oauth/access_token', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                Accept: 'application/json',
            },
            body: JSON.stringify({
                client_id: cfg.clientId,
                client_secret: cfg.clientSecret,
                code,
            }),
        });

        if (!tokenResponse.ok) {
            console.error('Token exchange failed:', tokenResponse.status);
            return {
                status: '401',
                statusDescription: 'Unauthorized',
                body: 'Token exchange failed',
            };
        }

        const tokenData = await tokenResponse.json();
        const accessToken = tokenData.access_token;

        if (!accessToken) {
            console.error('No access token in response');
            return {
                status: '401',
                statusDescription: 'Unauthorized',
                body: 'No access token received',
            };
        }

        const userResponse = await fetch('https://api.github.com/user', {
            headers: {
                Authorization: `Bearer ${accessToken}`,
                'User-Agent': 'Lambda-Edge-Auth',
            },
        });

        if (!userResponse.ok) {
            console.error('Failed to fetch user:', userResponse.status);
            return {
                status: '500',
                statusDescription: 'Internal Server Error',
                body: 'Failed to fetch user info',
            };
        }

        const userData = await userResponse.json();
        const username = userData.login;

        const membershipResponse = await fetch(
            `https://api.github.com/orgs/${encodeURIComponent(cfg.githubOrg)}/members/${encodeURIComponent(username)}`,
            {
                headers: {
                    Authorization: `Bearer ${accessToken}`,
                    'User-Agent': 'Lambda-Edge-Auth',
                },
            },
        );

        if (membershipResponse.status === 404) {
            return {
                status: '403',
                statusDescription: 'Forbidden',
                body: 'Not a member of the required organization',
            };
        }

        if (membershipResponse.status !== 204) {
            console.error('Membership check failed:', membershipResponse.status);
            return {
                status: '500',
                statusDescription: 'Internal Server Error',
                body: 'Failed to verify organization membership',
            };
        }

        // Generate session token instead of signed cookies
        const timestamp = Date.now().toString();
        const hmac = crypto.createHmac('sha256', cfg.sessionSecret);
        hmac.update(timestamp);
        const signature = hmac.digest('hex');
        const sessionToken = `${timestamp}.${signature}`;

        const cookieOptions = {
            domain: cfg.cloudfrontDomain,
            path: '/',
            httpOnly: true,
            secure: true,
            sameSite: 'Lax',
            maxAge: 86400,
        };

        const setCookieHeaders = [{
            key: 'Set-Cookie',
            value: serializeCookie('wiki-file-session', sessionToken, cookieOptions),
        }];

        return {
            status: '302',
            statusDescription: 'Found',
            headers: {
                location: [{ key: 'Location', value: `https://${cfg.cloudfrontDomain}/` }],
                'set-cookie': setCookieHeaders,
                'cache-control': [{ key: 'Cache-Control', value: 'no-cache, no-store, must-revalidate' }]
            },
        };
    } catch (err) {
        console.error('Callback error:', err);
        return {
            status: '500',
            statusDescription: 'Internal Server Error',
            body: 'Internal server error',
        };
    }
}

exports.handler = async (event) => {
    const request = event.Records[0].cf.request;

    if (!cfg.clientId) {
         return {
            status: '500',
            statusDescription: 'Internal Server Error',
            body: 'Missing configuration (config.json)',
        };
    }

    if (request.uri === '/login') {
        return login(request);
    }
    if (request.uri === '/callback') {
        return callback(request);
    }

    return {
        status: '404',
        statusDescription: 'Not Found',
        body: 'Not Found',
    };
};
