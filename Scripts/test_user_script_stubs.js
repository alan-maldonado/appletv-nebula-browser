// Verification step 3: DOM-lite stubs proving the popup-blocker /
// visibility-spoof user script behaves as specified:
//   1. window.open is blocked (null) for a cross-origin call from a sub-frame
//      without a recent user gesture.
//   2. window.open is allowed within 800 ms of a simulated gesture.
//   3. document.hidden is spoofed to false when a <video> exists.
//   4. With noMSE true, MediaSource/ManagedMediaSource are undefined and the
//      hls.js-style support check is false (Native Video Mode).
// Runs the script extracted from BrowserWebView.m (no mocks of the script).

const assert = require('assert');
const path = require('path');
const { extractAssembledScript } = require('./extract_user_scripts');

const webviewPath = path.join(__dirname, '..', '_Project', 'Browser', 'BrowserWebView.m');
const scriptSource = extractAssembledScript(webviewPath, 'BrowserPopupBlockerUserScriptWithFlags');

class FakeEvent {
    constructor(type) { this.type = type; }
}

function makeSandbox({ crossFrame }) {
    const windowListeners = {};
    const documentListeners = {};

    function Document() {}
    Object.defineProperty(Document.prototype, 'hidden', {
        configurable: true,
        get() { return this.__hidden === true; },
    });
    Object.defineProperty(Document.prototype, 'visibilityState', {
        configurable: true,
        get() { return this.__hidden === true ? 'hidden' : 'visible'; },
    });

    const document = new Document();
    document.__hidden = true; // pretend the page is "hidden" for spoof tests
    document.__videos = [];
    document.baseURI = 'https://embed.example.test/new-stream-embed/42?ad=111';
    document.querySelectorAll = () => [];
    document.getElementsByTagName = (tagName) => (tagName === 'video' ? document.__videos : []);
    document.addEventListener = (name, fn) => { (documentListeners[name] = documentListeners[name] || []).push(fn); };
    document.dispatchEvent = (event) => { (documentListeners[event.type] || []).forEach((fn) => fn(event)); return true; };

    const openedURLs = [];
    const window = {
        innerWidth: 1280,
        innerHeight: 720,
        open(url) { openedURLs.push(url); return { __nativeWindow: true }; },
        addEventListener(name, fn) { (windowListeners[name] = windowListeners[name] || []).push(fn); },
        getComputedStyle() { return { position: 'static', zIndex: 'auto' }; },
        setInterval() { return 0; }, // sweep must never actually run in tests
        location: { href: document.baseURI },
    };
    window.self = window;
    if (crossFrame) {
        // Sub-frame: window.top is a different document on a different origin.
        window.top = { location: { href: 'https://site.example.test/watch' } };
    } else {
        window.top = window;
    }

    const probeReports = [];
    window.webkit = { messageHandlers: { browserMediaProbe: { postMessage: (payload) => probeReports.push(payload) } } };

    const run = () => {
        // The user script runs at documentStart with these as the only globals
        // it touches beyond Math/Date/JSON.
        const factory = new Function('window', 'document', 'setInterval', 'Event', 'Document', scriptSource);
        factory(window, document, () => 0, FakeEvent, Document);
    };

    const fireWindow = (name) => { (windowListeners[name] || []).forEach((fn) => fn(new FakeEvent(name))); };
    const fireDocument = (name) => { (documentListeners[name] || []).forEach((fn) => fn(new FakeEvent(name))); };

    return { window, document, openedURLs, probeReports, run, fireWindow, fireDocument };
}

let failures = 0;
function check(name, fn) {
    try {
        fn();
        console.log(`PASS ${name}`);
    } catch (error) {
        failures += 1;
        console.error(`FAIL ${name}: ${error && error.message}`);
    }
}

// 1. Cross-origin (sub-frame) window.open without a gesture -> blocked (null)
//    and reported through the probe channel as {blocked:true, url}.
check('window.open blocked for cross-origin non-gesture call', () => {
    const sandbox = makeSandbox({ crossFrame: true });
    sandbox.run();
    const result = sandbox.window.open('https://ad.example.test/popup?id=1');
    assert.strictEqual(result, null, 'blocked window.open must return null');
    assert.deepStrictEqual(sandbox.openedURLs, [], 'native window.open must not be called');
    const report = sandbox.probeReports.find((payload) => payload.blocked === true);
    assert.ok(report, 'a blocked report must be posted through browserMediaProbe');
    assert.strictEqual(report.url, 'https://ad.example.test/popup?id=1');
});

// 2. Same call within the 800 ms gesture window -> allowed through.
check('window.open allowed within 800 ms of a simulated gesture', () => {
    const sandbox = makeSandbox({ crossFrame: true });
    sandbox.run();
    sandbox.fireWindow('pointerdown'); // capture-phase gesture tracker
    const result = sandbox.window.open('https://ad.example.test/popup?id=2');
    assert.deepStrictEqual(result, { __nativeWindow: true }, 'open must pass through after the gesture');
    assert.deepStrictEqual(sandbox.openedURLs, ['https://ad.example.test/popup?id=2']);
    assert.strictEqual(sandbox.probeReports.find((payload) => payload.blocked === true), undefined);
});

// 2b. Gesture window expiry: freeze Date.now just past 800 ms -> blocked again.
check('window.open blocked again 801 ms after the gesture', () => {
    const sandbox = makeSandbox({ crossFrame: true });
    const realNow = Date.now;
    try {
        const start = Date.now();
        Date.now = () => start;
        sandbox.run();
        sandbox.fireWindow('pointerdown');
        assert.deepStrictEqual(sandbox.window.open('https://ad.example.test/popup?a=1'), { __nativeWindow: true });
        Date.now = () => start + 801;
        assert.strictEqual(sandbox.window.open('https://ad.example.test/popup?a=2'), null);
    } finally {
        Date.now = realNow;
    }
});

// 3. Visibility spoof: with a <video> present and the flag on, document.hidden
//    reports false even though the real value is true; without a video the
//    real value shows through.
check('document.hidden spoof returns false when video present', () => {
    const sandbox = makeSandbox({ crossFrame: false });
    sandbox.run();
    assert.strictEqual(sandbox.document.hidden, true, 'no video yet: real hidden value must show');
    sandbox.document.__videos.push({});
    assert.strictEqual(sandbox.document.hidden, false, 'video present: hidden must be spoofed to false');
    assert.strictEqual(sandbox.document.visibilityState, 'visible', 'visibilityState must be spoofed too');
    sandbox.document.__videos.length = 0;
    assert.strictEqual(sandbox.document.hidden, true, 'video removed: real hidden value must show again');
});

// 3b. Becoming visible again re-dispatches a synthetic cancelable
//     visibilitychange, marked so the script does not loop.
check('synthetic visibilitychange dispatched when visible again', () => {
    const sandbox = makeSandbox({ crossFrame: false });
    sandbox.run();
    let syntheticSeen = 0;
    let normalSeen = 0;
    sandbox.document.addEventListener('visibilitychange', (event) => {
        if (event.__browserSyntheticVisibility) syntheticSeen += 1; else normalSeen += 1;
    });
    sandbox.document.__hidden = false; // page becomes visible
    sandbox.fireDocument('visibilitychange'); // real event
    assert.strictEqual(normalSeen, 1, 'the real event must reach page listeners exactly once');
    assert.strictEqual(syntheticSeen, 1, 'one synthetic (non-looping) event expected');
});

// 4. Native Video Mode noMSE: the extracted media-engine script (config
//    literals are all substituted with true by the extractor, so noMSE is
//    true) must make MediaSource and ManagedMediaSource undefined so the
//    hls.js support check fails and pages fall back to native HLS.
check('noMSE: MediaSource/ManagedMediaSource undefined, hls.js support check false', () => {
    const mediaEngineSource = extractAssembledScript(webviewPath, 'BrowserMediaEngineUserScriptWithFlags');
    const location = { href: 'https://player.example.test/new-stream-embed/42' };
    const window = {
        location,
        setInterval: () => 0, // probe interval must never actually run in tests
        MediaSource: function FakeMSE() {},
        ManagedMediaSource: function FakeMMS() {},
    };
    const document = {
        baseURI: location.href,
        location,
        addEventListener() {},
        querySelectorAll: () => [],
        createElement: () => { throw new Error('no DOM in tests'); },
    };
    const factory = new Function('window', 'document', 'setInterval', mediaEngineSource);
    factory(window, document, () => 0);
    assert.strictEqual(window.MediaSource, undefined, 'window.MediaSource must be undefined');
    assert.strictEqual(window.ManagedMediaSource, undefined, 'window.ManagedMediaSource must be undefined');
    assert.strictEqual(!!(window.MediaSource || window.ManagedMediaSource), false,
                       'hls.js isSupported() existence check must be false');
});

process.exit(failures === 0 ? 0 : 1);
