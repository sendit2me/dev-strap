import { defineConfig } from '@playwright/test';

export default defineConfig({
    testDir: '.',
    testMatch: '**/*.spec.ts',
    timeout: 30000,
    retries: 0,
    workers: 1,

    use: {
        baseURL: process.env.BASE_URL || 'http://web',
        ignoreHTTPSErrors: true,
        screenshot: 'on',
        trace: 'on-first-retry',
        video: 'retain-on-failure',
    },

    reporter: [
        ['html', { outputFolder: process.env.PLAYWRIGHT_HTML_REPORT || '/results/report', open: 'never' }],
        ['json', { outputFile: process.env.PLAYWRIGHT_JSON_OUTPUT_FILE || '/results/results.json' }],
        ['list'],
    ],

    outputDir: '/results/artifacts',
});
