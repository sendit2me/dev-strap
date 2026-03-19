import { test, expect } from '@playwright/test';

test.describe('Stateful Mock — Payment Checkout Flow', () => {

    test('checkout progresses through states: pending → processing → complete', async ({ request }) => {
        // Step 1: Create checkout session
        const createResponse = await request.post('/api/checkout');
        expect(createResponse.status()).toBe(201);

        const created = await createResponse.json();
        expect(created.intercepted).toBe(true);
        expect(created.status).toBe('pending');
        expect(created.id).toBe('cs_mock_12345');

        // Step 2: First poll — should be "processing"
        const poll1 = await request.get('/api/checkout/status');
        expect(poll1.ok()).toBeTruthy();

        const status1 = await poll1.json();
        expect(status1.status).toBe('processing');
        expect(status1.payment_status).toBe('requires_action');

        // Step 3: Second poll — should be "complete"
        const poll2 = await request.get('/api/checkout/status');
        expect(poll2.ok()).toBeTruthy();

        const status2 = await poll2.json();
        expect(status2.status).toBe('complete');
        expect(status2.payment_status).toBe('paid');
        expect(status2.amount_total).toBe(4999);
    });

});
