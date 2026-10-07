'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');

async function main() {
  assert.equal(process.argv.length, 3, 'expected the emcc-generated module path');
  const createZlua = require(path.resolve(process.argv[2]));
  const module = await createZlua();
  assert.equal(typeof module._zluaFfiWasmScenario, 'function', 'missing real scenario export');
  assert.equal(module._zluaFfiWasmScenario(), 0, 'Lua/libffi wasm round-trip scenario failed');
  console.log('Lua/libffi wasm functions and executable callbacks passed');
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
