'use strict';
const assert = require('node:assert/strict');
const path = require('node:path');

async function main() {
    const createModule = require(path.resolve(process.argv[2]));
    const module = await createModule();
    assert.equal(typeof module._zluaWasmScenario, 'function', 'missing Zig wasm entry point');
    assert.equal(module._zluaWasmScenario(), 0,
        'wasm Lua tables, control flow, stdlib, binary strings, callback, errors and recovery');
    console.log('zlua wasm: tables/control-flow/stdlib/binary/callback/protected-errors/recovery passed');
}
main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
