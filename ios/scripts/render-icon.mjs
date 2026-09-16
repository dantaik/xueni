// render-icon.mjs — the app icon PNG from scripts/icon.svg.
//
//   node ios/scripts/render-icon.mjs        (from the repository root,
//                                            after `npm install` in webapp/)
//
// Uses the Chromium that the web app's Playwright already carries rather
// than another dependency; the PNG it writes is committed, so this only
// needs running when the mark changes.

import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..', '..');
const require = createRequire(path.join(root, 'webapp', 'package.json'));
const { chromium } = require('@playwright/test');

const svg = readFileSync(path.join(root, 'ios', 'scripts', 'icon.svg'), 'utf8');
const out = path.join(root, 'ios', 'Xueni', 'Assets.xcassets', 'AppIcon.appiconset', 'icon-1024.png');

// PLAYWRIGHT_CHROMIUM names a Chromium to use instead of the one Playwright downloaded.
const browser = await chromium.launch(process.env.PLAYWRIGHT_CHROMIUM ? { executablePath: process.env.PLAYWRIGHT_CHROMIUM } : {});
const page = await browser.newPage({ viewport: { width: 1024, height: 1024 }, deviceScaleFactor: 1 });
await page.setContent(`<!doctype html><html><body style="margin:0;background:#111">${svg}</body></html>`);
await page.screenshot({ path: out, clip: { x: 0, y: 0, width: 1024, height: 1024 } });
await browser.close();
console.log(`wrote ${out}`);
