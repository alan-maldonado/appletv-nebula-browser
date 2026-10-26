// Verification step 2: extract the assembled user-script JavaScript from the
// Objective-C string literals and run `node --check` on each.
// Exit code != 0 when any extracted script fails to parse.

const { execFileSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { extractAssembledScript } = require('./extract_user_scripts');

const webviewPath = path.join(__dirname, '..', '_Project', 'Browser', 'BrowserWebView.m');
const outDir = fs.mkdtempSync(path.join(os.tmpdir(), 'nebula-user-script-check-'));

const targets = [
    { func: 'BrowserMediaEngineUserScriptWithFlags', file: 'media_engine_user_script.js' },
    { func: 'BrowserPopupBlockerUserScriptWithFlags', file: 'popup_blocker_user_script.js' },
];

let failures = 0;
for (const target of targets) {
    const assembled = extractAssembledScript(webviewPath, target.func);
    const outPath = path.join(outDir, target.file);
    fs.writeFileSync(outPath, assembled);
    try {
        execFileSync(process.execPath, ['--check', outPath], { stdio: 'pipe' });
        console.log(`node --check OK   ${target.func} (${assembled.length} bytes) -> ${outPath}`);
    } catch (error) {
        failures += 1;
        console.error(`node --check FAIL ${target.func}`);
        console.error(String(error.stderr || error.message));
    }
}
process.exit(failures === 0 ? 0 : 1);
