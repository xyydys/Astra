// 用法：node render.cjs <dir> name1 name2 ...  → 每个 name.svg 渲染成 name.png（1024），再出一张 sheet.png
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');
const [, , dir, ...names] = process.argv;

(async () => {
  const browser = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome' });
  const page = await browser.newPage({ viewport: { width: 1024, height: 1024 }, deviceScaleFactor: 1 });
  for (const name of names) {
    const svg = fs.readFileSync(path.join(dir, name + '.svg'), 'utf8');
    await page.setContent(`<html><body style="margin:0;background:#000">${svg}</body></html>`);
    await page.locator('svg').screenshot({ path: path.join(dir, name + '.png'), omitBackground: false });
  }
  // 预览图：模拟主屏的圆角遮罩，深浅两种背景 + 小尺寸
  const cells = (size, bg) => names.map(n => {
    const data = fs.readFileSync(path.join(dir, n + '.png')).toString('base64');
    return `<div style="text-align:center;color:${bg === '#111' ? '#ddd' : '#333'};font:14px sans-serif">
      <img src="data:image/png;base64,${data}" style="width:${size}px;height:${size}px;border-radius:${size * 0.225}px;box-shadow:0 ${size * 0.04}px ${size * 0.1}px rgba(0,0,0,.35)"/>
      ${size > 100 ? `<div>${n}</div>` : ''}</div>`;
  }).join('');
  const html = `<html><body style="margin:0">
    <div style="background:#111;display:flex;flex-wrap:wrap;gap:36px;padding:36px">${cells(220, '#111')}</div>
    <div style="background:#e9e6f2;display:flex;flex-wrap:wrap;gap:24px;padding:24px 36px">${cells(64, '#eee')}</div>
  </body></html>`;
  const sheet = await browser.newPage({ viewport: { width: 1100, height: 400 }, deviceScaleFactor: 1 });
  await sheet.setContent(html);
  await sheet.screenshot({ path: path.join(dir, 'sheet.png'), fullPage: true });
  await browser.close();
})();
