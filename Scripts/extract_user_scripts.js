// Extracts the assembled JavaScript out of the Objective-C string-literal
// builders in BrowserWebView.m (pattern: NSString *config = stringWithFormat…
// followed by NSString *script = "…" "…" … ; return [config stringByAppendingString:script]).
// Config %@ placeholders are substituted with "true" so every gated section is
// present in the extracted source; pass flagValues (aligned with the %@ order)
// to substitute specific values per placeholder instead.
//
// Usage (as a module): const { extractAssembledScript } = require('./extract_user_scripts');

const fs = require('fs');

// Scans double-quoted C/ObjC literals ("…" or @"…") from `start` onward.
// Returns [{ content }] with C escapes (\", \\, \n, \t) already resolved.
function scanLiterals(source, start, end) {
    const literals = [];
    let i = start;
    while (i < end) {
        if (source[i] === '"') {
            let j = i + 1;
            let raw = '';
            while (j < end) {
                const ch = source[j];
                if (ch === '\\') { raw += source[j] + (source[j + 1] || ''); j += 2; continue; }
                if (ch === '"') break;
                raw += ch;
                j += 1;
            }
            literals.push({ content: unescapeC(raw) });
            i = j + 1;
            continue;
        }
        i += 1;
    }
    return literals;
}

function unescapeC(raw) {
    return raw.replace(/\\(?:([nt"\\])|u([0-9a-fA-F]{4})|.)/g, (match, simple, hex) => {
        if (simple === 'n') return '\n';
        if (simple === 't') return '\t';
        if (simple === '"') return '"';
        if (simple === '\\') return '\\';
        if (hex !== undefined) return String.fromCharCode(parseInt(hex, 16));
        return '';
    });
}

function extractAssembledScript(sourcePath, funcName, flagValues) {
    const source = fs.readFileSync(sourcePath, 'utf8');
    const start = source.indexOf(funcName);
    if (start === -1) throw new Error(`function ${funcName} not found in ${sourcePath}`);
    const returnMarker = 'return [config stringByAppendingString:script];';
    const bodyEnd = source.indexOf(returnMarker, start);
    if (bodyEnd === -1) throw new Error(`"${returnMarker}" not found after ${funcName}`);
    const body = source.slice(start, bodyEnd);

    const scriptMarker = 'NSString *script =';
    const scriptStart = body.indexOf(scriptMarker);
    if (scriptStart === -1) throw new Error(`"${scriptMarker}" not found in ${funcName}`);

    // Config: the stringWithFormat format literal, %@ -> true (all sections on)
    // unless per-placeholder flagValues are supplied.
    const configPart = body.slice(0, scriptStart);
    const configLiterals = scanLiterals(configPart, 0, configPart.length);
    const formatLiteral = configLiterals.find((literal) => literal.content.includes('%@'));
    if (!formatLiteral) throw new Error(`no %@ format literal found in ${funcName}`);
    const segments = formatLiteral.content.split('%@');
    const placeholderCount = segments.length - 1;
    if (Array.isArray(flagValues) && flagValues.length !== placeholderCount) {
        throw new Error(`${funcName}: got ${flagValues.length} flagValues for ${placeholderCount} %@ placeholders`);
    }
    let configJS = segments[0];
    for (let i = 0; i < placeholderCount; i += 1) {
        configJS += (Array.isArray(flagValues) ? String(flagValues[i]) : 'true') + segments[i + 1];
    }

    // Script: every literal in the concatenation chain, in order.
    const scriptPart = body.slice(scriptStart + scriptMarker.length);
    const scriptJS = scanLiterals(scriptPart, 0, scriptPart.length).map((literal) => literal.content).join('');

    return configJS + scriptJS;
}

module.exports = { extractAssembledScript };

if (require.main === module) {
    const path = require('path');
    const os = require('os');
    const webviewPath = path.join(__dirname, '..', '_Project', 'Browser', 'BrowserWebView.m');
    const outDir = process.argv[2] || fs.mkdtempSync(path.join(os.tmpdir(), 'nebula-userscripts-'));
    const targets = [
        { func: 'BrowserMediaEngineUserScriptWithFlags', file: 'media_engine_user_script.js' },
        { func: 'BrowserPopupBlockerUserScriptWithFlags', file: 'popup_blocker_user_script.js' },
    ];
    for (const target of targets) {
        const assembled = extractAssembledScript(webviewPath, target.func);
        const outPath = path.join(outDir, target.file);
        fs.writeFileSync(outPath, assembled);
        console.log(`extracted ${target.func} -> ${outPath} (${assembled.length} bytes)`);
    }
}
