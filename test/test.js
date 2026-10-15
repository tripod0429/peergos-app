import assert from 'node:assert/strict';
import { By } from 'selenium-webdriver';
import { app, browser, clearCache, cloudronCli, goto, setupBrowser, takeScreenshot, teardownBrowser, waitForScript } from './helpers.js';

/* global it, describe, before, after, afterEach */

describe('Application life cycle test', function () {
    // Peergos usernames are global across the Peergos network, so every signup needs a fresh one
    const newUsername = () => `cloudrontest${Date.now().toString(36)}`;
    const PASSWORD = 'correct-horse-battery-staple-' + Math.random().toString(36).slice(2);
    const FOLDER = 'cloudron-test-folder';

    // Key derivation (scrypt) runs in the browser, and the first start syncs with the Peergos PKI
    const SLOW = 5 * 60 * 1000;

    const ORIGINAL_FQDN = app.fqdn;
    const [firstLabel, ...rest] = app.fqdn.split('.');
    const MOVED_FQDN = [`${firstLabel}2`, ...rest].join('.');

    let username;

    before(setupBrowser);
    after(teardownBrowser);

    afterEach(async function () {
        await takeScreenshot(this.currentTest);
    });

    // Finds Vue components from a script by walking the component tree from #app, breadth
    // first, so the shallowest match wins. Peergos 1.38 ships Vue 3, which keeps no instance
    // on elements in a production build, so the walk goes through vnodes the way upstream's
    // own tests do (Peergos/web-ui browser_tests/Page.java). Peergos 1.37 and older ship Vue 2,
    // where the root instance is on #app.__vue__ and children are in $children. The update test
    // still starts from such a version.
    const VUE = `(window.__pgVue || (window.__pgVue = {
        root() {
            const a = document.querySelector('#app');
            if (!a) return null;
            if (a._vnode && a._vnode.component) return a._vnode.component.proxy;
            return a.__vue__ || null;
        },
        children(c) {
            if (!c.$) return c.$children || [];
            const out = [];
            const walk = v => { if (v == null || typeof v !== 'object') return;
                if (Array.isArray(v)) { v.forEach(walk); return; }
                if (v.component) { if (v.component.proxy) out.push(v.component.proxy); else walk(v.component.subTree); return; }
                if (v.suspense) { walk(v.suspense.activeBranch); return; }
                walk(v.children); };
            walk(c.$.subTree); return out; },
        find(method) { const q = []; const r = this.root(); if (r) q.push(r);
            while (q.length) { const c = q.shift();
                if (typeof c[method] === 'function' && c.$el && c.$el.nodeType === 1 && document.contains(c.$el)) return c;
                q.push(...this.children(c)); }
            return null; }
    }))`;

    // Typing races the Vue models on these forms and can leave the username empty, so values
    // go in through the native setter plus an input event, like upstream's tests do.
    const SET_INPUT = `const set = (el, v) => {
        Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(el, v);
        el.dispatchEvent(new Event('input', { bubbles: true }));
    };`;

    function signupTokens() {
        return [...cloudronCli.logs().matchAll(/\?signup=true&token=([0-9a-f]+)/g)].map(m => m[1]);
    }

    async function waitForDrive() {
        await waitForScript('the drive to load', `(() => {
            const c = ${VUE}.find('downloadFile');
            if (c) window.__drive = c;
            return !!c && !!c.currentDir && !c.showSpinner;
        })()`, SLOW);
    }

    async function signUp() {
        let token;
        await browser.wait(() => (token = signupTokens().at(-1)), SLOW, 'No signup link in the app logs');
        username = newUsername();

        await goto(`https://${app.fqdn}/?signup=true&token=${token}`);
        await waitForScript('the signup form to connect', `(() => { const c = ${VUE}.find('signup'); return !!c && c.network != null; })()`, SLOW);
        await browser.executeScript(`${SET_INPUT}
            set(document.querySelector('.app-signup input[name=username]'), arguments[0]);
            document.querySelectorAll('.app-signup input[name=password]').forEach(el => set(el, arguments[1]));
            for (const name of ['safePassword', 'tosAccepted']) {
                const box = document.querySelector('.app-signup input[name=' + name + ']');
                if (!box.checked) box.click();
            }`, username, PASSWORD);
        await browser.findElement(By.css('.app-signup button.signup')).click();
        await waitForDrive();
    }

    async function login() {
        const signInEnabled = `[...document.querySelectorAll('button')].some(b => b.textContent.trim() === 'Sign in' && !b.disabled)`;

        await goto(`https://${app.fqdn}/`);
        await waitForScript('the sign in button', signInEnabled, SLOW);
        await browser.executeScript(`${SET_INPUT}
            set(document.querySelector('input[name=username]'), arguments[0]);
            set(document.querySelector('input[name=password]'), arguments[1]);
            [...document.querySelectorAll('button')].find(b => b.textContent.trim() === 'Sign in').click();`, username, PASSWORD);
        await waitForDrive();
    }

    async function logout() {
        await waitForScript('the logout action', `(() => { const c = ${VUE}.find('logout'); if (c) window.__settings = c; return !!c; })()`);
        await browser.executeScript('window.__settings.logout();');
        await waitForScript('the login form', `!!document.querySelector('input[name=username]')`, 120_000);
    }

    async function createFolder() {
        await browser.executeScript('window.__drive.mkdir(arguments[0]);', FOLDER);
        await checkFolder();
    }

    async function checkFolder() {
        await waitForScript(`folder ${FOLDER} in the drive`, `document.body.innerText.includes(${JSON.stringify(FOLDER)})`, 120_000);
    }

    let tokenCount;
    function rememberTokens() {
        tokenCount = signupTokens().length;
        assert.ok(tokenCount > 0, 'the first start printed no signup link');
    }

    function checkNoNewToken() {
        assert.ok(signupTokens().length <= tokenCount, 'Peergos printed another signup link after the first start');
    }

    it('install app', cloudronCli.install);

    it('can sign up with the token from the logs', signUp);
    it('can create a folder', createFolder);
    it('can log out', logout);
    it('can log in', login);
    it('sees the folder', checkFolder);
    it('remembers the signup links', rememberTokens);
    it('can log out', logout);

    it('restart app', cloudronCli.restart);

    it('can log in', login);
    it('sees the folder', checkFolder);
    it('printed no new signup link', checkNoNewToken);
    it('can log out', logout);

    it('backup app', cloudronCli.createBackup);
    it('restore app', cloudronCli.restoreFromLatestBackup);

    it('can log in', login);
    it('sees the folder', checkFolder);
    it('printed no new signup link', checkNoNewToken);
    it('can log out', logout);

    it('move to different location', function () { cloudronCli.changeLocation(MOVED_FQDN); });

    it('can log in', login);
    it('sees the folder', checkFolder);
    it('can log out', logout);

    it('uninstall app', cloudronCli.uninstall);

    // Updating needs a previously published version. Set VERSIONS_URL to the hosted
    // CloudronVersions.json to run this part.
    describe('update from the published version', function () {
        before(function () {
            if (!process.env.VERSIONS_URL) this.skip();
            app.fqdn = ORIGINAL_FQDN;
        });

        it('install published version', function () { cloudronCli.installFromVersions(process.env.VERSIONS_URL); });
        // the service worker from the first run would otherwise serve the newer web UI
        it('clear browser state', clearCache);

        it('can sign up with the token from the logs', signUp);
        it('can create a folder', createFolder);
        it('can log out', logout);

        it('update app', cloudronCli.update);

        it('can log in', login);
        it('sees the folder', checkFolder);
        it('can log out', logout);

        it('uninstall app', cloudronCli.uninstall);
    });
});
