'use strict';

const test = require('node:test');
const assert = require('node:assert');
const crypto = require('node:crypto');

test('app.js handler', async (t) => {
    // Generate a temporary RSA key pair for testing
    const { privateKey } = crypto.generateKeyPairSync('rsa', {
        modulusLength: 2048,
        publicKeyEncoding: { type: 'spki', format: 'pem' },
        privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
    });

    // Inject configuration into global object BEFORE requiring app.js
    global.__CONFIG__ = {
        clientId: 'id',
        clientSecret: 'secret',
        githubOrg: 'my-org',
        cloudfrontDomain: 'example.com',
        cloudfrontKeyId: 'K123456789',
        privateKeyPem: privateKey,
    };

    const { handler } = require('../src/app.js');
    const originalFetch = global.fetch;
    
    t.afterEach(() => {
        global.fetch = originalFetch;
    });

    await t.test('login route redirects to GitHub', async () => {
        const event = {
            Records: [{
                cf: {
                    request: {
                        uri: '/login',
                        headers: {
                            host: [{ key: 'Host', value: 'example.com' }]
                        }
                    }
                }
            }]
        };

        const response = await handler(event);
        assert.strictEqual(response.status, '302');
        assert.ok(response.headers.location[0].value.includes('github.com/login/oauth/authorize'));
        assert.ok(response.headers.location[0].value.includes('redirect_uri=https%3A%2F%2Fexample.com%2Fcallback'));
    });

    await t.test('callback route generates signed cookies', async () => {
        const event = {
            Records: [{
                cf: {
                    request: {
                        uri: '/callback',
                        querystring: 'code=test-code',
                        headers: {}
                    }
                }
            }]
        };

        global.fetch = async (url) => {
            if (url === 'https://github.com/login/oauth/access_token') {
                return { ok: true, json: async () => ({ access_token: 'fake-token' }) };
            }
            if (url === 'https://api.github.com/user') {
                return { ok: true, json: async () => ({ login: 'testuser' }) };
            }
            if (url === 'https://api.github.com/orgs/my-org/members/testuser') {
                return { status: 204, ok: true };
            }
            return { ok: false };
        };

        const response = await handler(event);
        assert.strictEqual(response.status, '302');
        assert.strictEqual(response.headers.location[0].value, 'https://example.com/');
        
        const cookies = response.headers['set-cookie'];
        assert.strictEqual(cookies.length, 3);
        
        const cookieNames = cookies.map(c => decodeURIComponent(c.value.split('=')[0]));
        assert.ok(cookieNames.includes('CloudFront-Policy'));
        assert.ok(cookieNames.includes('CloudFront-Signature'));
        assert.ok(cookieNames.includes('CloudFront-Key-Pair-Id'));
        
        const keyIdCookie = cookies.find(c => c.value.includes('CloudFront-Key-Pair-Id'));
        assert.ok(keyIdCookie.value.includes('K123456789'));
    });

    await t.test('returns 500 if missing configuration', async () => {
        // Backup the config and temporarily break it
        const backupConfig = global.__CONFIG__.clientId;
        global.__CONFIG__.clientId = null;

        const event = {
            Records: [{
                cf: {
                    request: {
                        uri: '/login',
                        headers: {}
                    }
                }
            }]
        };

        const response = await handler(event);
        assert.strictEqual(response.status, '500');
        assert.ok(response.body.includes('Missing configuration'));

        // Restore config
        global.__CONFIG__.clientId = backupConfig;
    });
});
