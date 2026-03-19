import { test, expect } from '@playwright/test';

test.describe('Conditional Mock — Amount-based Branching', () => {

    test('normal amount auto-approves', async ({ request }) => {
        const response = await request.post('/api/charge', {
            data: { amount: 2500, currency: 'usd' }
        });
        expect(response.ok()).toBeTruthy();

        const body = await response.json();
        expect(body.intercepted).toBe(true);
        expect(body.status).toBe('succeeded');
        expect(body.requested_amount).toBe(2500);
    });

    test('high-value amount requires review', async ({ request }) => {
        const response = await request.post('/api/charge', {
            data: { amount: 15000, currency: 'usd' }
        });
        expect(response.ok()).toBeTruthy();

        const body = await response.json();
        expect(body.intercepted).toBe(true);
        expect(body.status).toBe('requires_review');
        expect(body.requested_amount).toBe(15000);
    });

});
