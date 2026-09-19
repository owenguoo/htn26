const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');

const html = fs.readFileSync('web/console.html', 'utf8');

test('expanded camera viewer uses a tall viewport-relative frame', () => {
  const box = html.match(/\.vbox\s*\{([^}]+)\}/)?.[1] ?? '';
  assert.match(box, /height:\s*min\(88dvh,\s*960px\)/);
  assert.match(box, /max-height:\s*100%/);
});

test('video stage consumes remaining height without distorting portrait video', () => {
  const stage = html.match(/\.vimg\s*\{([^}]+)\}/)?.[1] ?? '';
  const image = html.match(/\.vimg img\s*\{([^}]+)\}/)?.[1] ?? '';
  assert.match(stage, /flex:\s*1 1 0/);
  assert.match(stage, /min-height:\s*320px/);
  assert.match(image, /max-height:\s*100%/);
  assert.match(image, /object-fit:\s*contain/);
  assert.doesNotMatch(image, /66vh/);
});
