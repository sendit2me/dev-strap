import { test, expect } from '@playwright/test';

test.describe('Simple Mock Interception', () => {

    test('fetches items from mocked external API', async ({ request }) => {
        const response = await request.get('/api/items');
        expect(response.ok()).toBeTruthy();

        const body = await response.json();

        // Verify the response came through the mock
        expect(body.intercepted).toBe(true);
        expect(body.source).toBe('api.example-provider.com');

        // Verify mock data
        expect(body.items).toHaveLength(3);
        expect(body.items[0].id).toBe('item_001');
        expect(body.items[0].name).toBe('Widget A');
        expect(body.total).toBe(3);
    });

});
