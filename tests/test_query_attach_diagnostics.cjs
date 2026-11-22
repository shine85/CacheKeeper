'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '../scripts/resource_access_probe.js'), 'utf8');
const start = source.indexOf('function queryAttachError(');
const end = source.indexOf('\nconst receipt', start);
assert.ok(start >= 0 && end > start);
const context = { Error };
vm.runInNewContext(source.slice(start, end), context);
for (const [message, expected] of [
  ['unable to intercept function at 0x123; please file a bug', 'interceptionFailed'],
  ['unable to intercept instruction at 0x123; please file a bug', 'interceptionFailed'],
  ['unable to intercept function at 0x123; no instruction could be decoded there', 'invalidInstruction'],
  ['already attached to this function', 'alreadyAttached'],
  ['not permitted by code-signing policy', 'codeSigningPolicy'],
  ['wrong type', 'wrongType'],
  ['/private/var/mobile/private-canary', 'unclassified'],
]) assert.equal(context.queryAttachError(new Error(message)), expected);
assert.equal(context.queryAttachError({ message: 'already attached to this function' }), 'unclassified');
console.log('PASS: query attach failures preserve observed errors without inventing an ABI cause');
