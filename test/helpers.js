// Stand-ins for the helpers official Cloudron app tests import from
// @cloudron/charlie. The npm release of charlie (0.1.0) is only a test runner,
// so these keep the same names: switching later means changing one import.

import { execSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { Builder } from 'selenium-webdriver';
import chrome from 'selenium-webdriver/chrome.js';

if (!process.env.LOCATION) throw new Error('Set LOCATION to the domain to install the test app at, e.g. LOCATION=peergos-test.example.com');

const PACKAGE_DIR = path.resolve(import.meta.dirname, '..');
const SCREENSHOT_DIR = path.join(import.meta.dirname, 'screenshots');
const IMAGE = process.env.IMAGE || '';

export const app = { fqdn: process.env.LOCATION };
export let browser = null;

export async function setupBrowser() {
    const options = new chrome.Options();
    if (!process.env.SHOW_BROWSER) options.addArguments('--headless=new');
    options.addArguments('--window-size=1280,1024');
    // Selenium Manager downloads chromedriver, and Chrome for Testing when no Chrome is installed
    browser = await new Builder().forBrowser('chrome').setChromeOptions(options).build();
}

export async function teardownBrowser() {
    if (browser) await browser.quit();
}

export async function takeScreenshot(test) {
    if (!browser || test.state !== 'failed') return;
    fs.mkdirSync(SCREENSHOT_DIR, { recursive: true });
    const name = test.fullTitle().replace(/[^a-z0-9]+/gi, '-').toLowerCase();
    fs.writeFileSync(path.join(SCREENSHOT_DIR, `${name}.png`), await browser.takeScreenshot(), 'base64');
}

// Waits until a JavaScript expression is truthy in the page. A navigation in
// progress makes executeScript throw, which counts as "not yet".
export async function waitForScript(description, expression, timeout = 60_000) {
    await browser.wait(async function () {
        try {
            return !!(await browser.executeScript(`return ${expression}`));
        } catch {
            return false;
        }
    }, timeout, `Timed out after ${timeout / 1000}s waiting for ${description}`);
}

export async function goto(url) {
    await browser.get(url);
}

// Forgets everything the browser holds for the app's origin, including the
// service worker, so the next visit starts like a new visitor.
export async function clearCache() {
    await browser.get(`https://${app.fqdn}/`);
    await browser.executeScript(`
        localStorage.clear();
        sessionStorage.clear();
        return navigator.serviceWorker ? navigator.serviceWorker.getRegistrations().then(rs => Promise.all(rs.map(r => r.unregister()))) : null;
    `);
    await browser.manage().deleteAllCookies();
}

function cloudron(args, { capture = false } = {}) {
    if (!capture) console.log(`      $ cloudron ${args}`);
    return execSync(`cloudron ${args}`, {
        cwd: PACKAGE_DIR,
        encoding: 'utf8',
        maxBuffer: 64 * 1024 * 1024,
        stdio: capture ? ['ignore', 'pipe', 'inherit'] : 'inherit'
    });
}

const imageArg = IMAGE ? ` --image ${IMAGE}` : '';
// Host port for P2P over TCP and UDP. Needed when another Peergos on the server already has 4001.
const portArg = process.env.P2P_PORT ? ` -p IPFS_TCP_PORT=${process.env.P2P_PORT},IPFS_UDP_PORT=${process.env.P2P_PORT}` : '';

export const cloudronCli = {
    // Without IMAGE the package is built on the server from this directory
    install() { cloudron(`install --location ${app.fqdn}${portArg}${imageArg}`); },
    installFromVersions(versionsUrl) { cloudron(`install --location ${app.fqdn}${portArg} --versions-url ${versionsUrl}`); },
    // --force: an app installed from CloudronVersions.json changes its source when it moves to this build
    update() { cloudron(`update --app ${app.fqdn} --force${imageArg}`); },
    uninstall() { cloudron(`uninstall --app ${app.fqdn}`); },
    restart() { cloudron(`restart --app ${app.fqdn}`); },
    // For an app that won't pass its health check
    restartNoWait() { cloudron(`--no-wait restart --app ${app.fqdn}`); },
    exec(command) { cloudron(`exec --app ${app.fqdn} -- ${command}`); },
    createBackup() { cloudron(`backup create --app ${app.fqdn}`); },
    restoreFromLatestBackup() { cloudron(`restore --app ${app.fqdn}`); },
    changeLocation(newFqdn) {
        cloudron(`configure --app ${app.fqdn} --location ${newFqdn}`);
        app.fqdn = newFqdn;
    },
    // Peergos logs thousands of lines while it first syncs with the network, which would push
    // its startup output (and the signup link) out of a smaller window
    logs(lines = 100000) { return cloudron(`logs --app ${app.fqdn} --lines ${lines}`, { capture: true }); }
};
