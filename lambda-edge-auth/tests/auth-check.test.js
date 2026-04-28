'use strict';

const test = require('node:test');
const assert = require('node:assert');
const { handler } = require('../auth-check.js');

test('auth-check handler', async (t) => {
    await t.test('redirects to /login if no signed cookie', async () => {
        const event = {
            Records: [{
                cf: {
                    request: {
                        uri: '/',
                        headers: {}
                    }
                }
            }]
        };

        const response = await handler(event);
        assert.strictEqual(response.status, '302');
        assert.strictEqual(response.headers.location[0].value, '/login');
    });

    await t.test('allows request if CloudFront-Signature cookie is present', async () => {
        const event = {
            Records: [{
                cf: {
                    request: {
                        uri: '/',
                        headers: {
                            cookie: [{ key: 'Cookie', value: 'CloudFront-Signature=fake-signature' }]
                        }
                    }
                }
            }]
        };

        const response = await handler(event);
        assert.deepStrictEqual(response.uri, '/');
    });

    await t.test('skips auth for /login path', async () => {
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
        assert.deepStrictEqual(response.uri, '/login');
    });

    await t.test('skips auth for /callback path', async () => {
        const event = {
            Records: [{
                cf: {
                    request: {
                        uri: '/callback',
                        headers: {}
                    }
                }
            }]
        };

        const response = await handler(event);
        assert.deepStrictEqual(response.uri, '/callback');
    });
});
