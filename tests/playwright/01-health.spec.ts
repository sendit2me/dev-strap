import { test, expect } from '@playwright/test';

test.describe('Application Health', () => {

    test('home page loads', async ({ page }) => {
        await page.goto('/');
        await expect(page).toHaveTitle('DevStack Example App');
        await expect(page.locator('h1')).toContainText('DevStack Example App');
    });

    test('health endpoint responds', async ({ request }) => {
        const response = await request.get('/health');
        expect(response.ok()).toBeTruthy();
        const body = await response.json();
        expect(body.status).toBe('ok');
        expect(body.timestamp).toBeTruthy();
    });

});
