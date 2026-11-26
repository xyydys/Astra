// Scope AMLL's pinned desktop hover rules to devices with a fine, hoverable primary pointer.
const fs = require('node:fs');
const path = require('node:path');
const { createRequire } = require('node:module');

const fromFolia = createRequire(path.resolve(process.argv[2], 'package.json'));
const postcss = fromFolia('postcss');
const file = fromFolia.resolve('@applemusic-like-lyrics/core/style.css');
const root = postcss.parse(fs.readFileSync(file, 'utf8'), { from: file });
const hoverRules = [];
root.walkRules(rule => {
    if (rule.selector.includes(':hover')) hoverRules.push(rule);
});

// AMLL 0.6.0 has two: the row highlight and the container-wide removal of blur.
// Fail loudly if an upgrade changes them, so touch devices don't silently regress.
if (hoverRules.length !== 2 ||
    !hoverRules.some(rule => rule.nodes.some(node => node.prop === 'filter' && node.important)) ||
    !hoverRules.some(rule => rule.nodes.some(node => node.prop === 'background-color'))) {
    throw new Error('AMLL hover CSS changed; review its touch hover rules');
}

for (const rule of hoverRules) {
    const media = postcss.atRule({ name: 'media', params: '(hover: hover) and (pointer: fine)' });
    rule.replaceWith(media.append(rule.clone()));
}
fs.writeFileSync(file, root.toString());
