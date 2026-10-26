// Verification for -ForcePlayOnLaunch: runs the media-engine user script
// extracted from BrowserWebView.m against DOM-lite stubs and proves
//   1. forcePlay flag OFF -> no play() call, no [ForcePlay] log, and the
//      probe report (shape + channel) is untouched.
//   2. forcePlay flag ON  -> the largest visible ready/paused video gets
//      muted=true and play() exactly once, one [ForcePlay] log line, later
//      ticks do nothing (window.__nebulaForcedPlay guard).
// The last %@ placeholder of the config literal is the ForcePlayOnLaunch
// flag (see BrowserMediaEngineUserScriptWithFlags in BrowserWebView.m).

const assert = require('assert');
const path = require('path');
const { extractAssembledScript } = require('./extract_user_scripts');

const webviewPath = path.join(__dirname, '..', '_Project', 'Browser', 'BrowserWebView.m');

// Config placeholders in BrowserMediaEngineUserScriptWithFlags order:
// hls, net, src, probe, noMSE, forcePlay.
function makeFlags(forcePlay) {
    return ['true', 'true', 'true', 'true', 'true', forcePlay ? 'true' : 'false'];
}

function makeVideo({ width, height, readyState, src, paused }) {
    const events = [];
    const video = {
        videoWidth: width,
        videoHeight: height,
        readyState,
        src: src || '',
        currentSrc: '',
        paused,
        playCalls: 0,
        play() {
            video.playCalls += 1;
            events.push(`play(muted=${video.muted})`); // muted must be set before play()
            return Promise.resolve();
        },
    };
    Object.defineProperty(video, 'muted', {
        configurable: true,
        get() { return video.__muted; },
        set(value) { video.__muted = value; events.push('muted=' + value); },
    });
    return { video, events };
}

function makeSandbox({ forcePlay, videos }) {
    const source = extractAssembledScript(webviewPath, 'BrowserMediaEngineUserScriptWithFlags', makeFlags(forcePlay));
    const location = { href: 'https://player.example.test/new-stream-embed/42' };
    const intervalCallbacks = [];
    const probeReports = [];
    const logs = [];

    const window = {
        location,
        setInterval: (fn) => { intervalCallbacks.push(fn); return intervalCallbacks.length; },
        webkit: { messageHandlers: { browserMediaProbe: { postMessage: (payload) => probeReports.push(payload) } } },
        addEventListener() {},
    };
    const document = {
        baseURI: location.href,
        location,
        addEventListener() {},
        createElement: () => ({ canPlayType: () => '' }), // no native HLS -> skip Hls shadowing
        querySelectorAll: (selector) => (selector === 'video' ? videos.map((entry) => entry.video) : []),
    };
    const console_ = { log: (message) => logs.push(String(message)) };

    const run = () => {
        const factory = new Function('window', 'document', 'setInterval', 'console', source);
        factory(window, document, window.setInterval, console_);
    };
    const tickIntervals = () => intervalCallbacks.slice().forEach((fn) => fn());

    return { window, probeReports, logs, run, tickIntervals, intervalCount: () => intervalCallbacks.length };
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

// 1. Flag OFF: no forced play anywhere, probe reporting keeps working with
//    its existing payload shape through the existing channel.
check('forcePlay OFF: no play(), no log, probe report shape untouched', () => {
    const small = makeVideo({ width: 120, height: 80, readyState: 4, src: 'https://cdn.example.test/small.mp4', paused: true });
    const big = makeVideo({ width: 640, height: 360, readyState: 3, src: 'https://cdn.example.test/big.m3u8.mp4', paused: true });
    const sandbox = makeSandbox({ forcePlay: false, videos: [small, big] });
    sandbox.run();
    sandbox.tickIntervals();
    sandbox.tickIntervals();
    assert.strictEqual(big.video.playCalls, 0, 'play() must never be called with the flag off');
    assert.strictEqual(small.video.playCalls, 0, 'play() must never be called with the flag off (small video)');
    assert.strictEqual(sandbox.logs.filter((line) => line.includes('[ForcePlay]')).length, 0);
    assert.strictEqual(sandbox.window.__nebulaForcedPlay, undefined);
    // Probe still posts {pageURL, videos, captured} through browserMediaProbe.
    assert.ok(sandbox.probeReports.length >= 1, 'probe reporting must still run with the flag off');
    const report = sandbox.probeReports[0];
    assert.deepStrictEqual(Object.keys(report).sort(), ['captured', 'pageURL', 'videos']);
    assert.strictEqual(report.videos[0].paused, true);
});

// 2. Flag ON: the largest visible ready video is muted + played exactly once
//    (muted before play), one [ForcePlay] log, guard blocks later attempts.
check('forcePlay ON: mutes and plays the largest ready video once', () => {
    const small = makeVideo({ width: 120, height: 80, readyState: 4, src: 'https://cdn.example.test/small.mp4', paused: true });
    const notReady = makeVideo({ width: 1280, height: 720, readyState: 0, src: '', paused: true }); // largest, but no src/ready -> must be skipped
    const big = makeVideo({ width: 640, height: 360, readyState: 3, src: 'https://cdn.example.test/big.m3u8.mp4', paused: true });
    const sandbox = makeSandbox({ forcePlay: true, videos: [small, notReady, big] });
    sandbox.run();
    sandbox.tickIntervals();
    assert.strictEqual(big.video.playCalls, 1, 'the largest visible ready video must be played');
    assert.strictEqual(big.video.muted, true, 'muted must be true');
    assert.strictEqual(big.video.__muted, true);
    assert.deepStrictEqual(big.events, ['muted=true', 'play(muted=true)'], 'muted must be set before play()');
    assert.strictEqual(small.video.playCalls, 0, 'the smaller video must not be played');
    assert.strictEqual(notReady.video.playCalls, 0, 'the not-ready video must be skipped');
    const forceLogs = sandbox.logs.filter((line) => line.includes('[ForcePlay] forced play attempt'));
    assert.strictEqual(forceLogs.length, 1, 'exactly one [ForcePlay] log line');
    assert.strictEqual(sandbox.window.__nebulaForcedPlay, true, 'one-shot guard set');
    // Later ticks must not repeat the attempt.
    sandbox.tickIntervals();
    sandbox.tickIntervals();
    assert.strictEqual(big.video.playCalls, 1, 'play() must stay a one-shot per document');
    assert.strictEqual(sandbox.logs.filter((line) => line.includes('[ForcePlay] forced play attempt')).length, 1);
});

// 3. Flag ON with no eligible video: nothing plays, but the guard stays unset
//    so a later-loaded video is still picked up once it is ready.
check('forcePlay ON without an eligible video: no attempt, guard stays unset', () => {
    const small = makeVideo({ width: 120, height: 80, readyState: 4, src: 'https://cdn.example.test/small.mp4', paused: true });
    const sandbox = makeSandbox({ forcePlay: true, videos: [small] });
    sandbox.run();
    sandbox.tickIntervals();
    assert.strictEqual(small.video.playCalls, 0);
    assert.strictEqual(sandbox.logs.filter((line) => line.includes('[ForcePlay]')).length, 0);
    assert.strictEqual(sandbox.window.__nebulaForcedPlay, undefined);
});

process.exit(failures === 0 ? 0 : 1);
