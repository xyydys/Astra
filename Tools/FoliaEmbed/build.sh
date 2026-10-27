#!/usr/bin/env bash
# 把 Folia（AGPL-3.0）的歌词特效打包成 App 内嵌页面，输出到 Embed/folia。
# 用的是 folia-major 固定版本的源码 + 本目录下的入口文件（embed/、folia-embed.html、vite.embed.config.ts）。
# 同一个页面里还有仿 Apple Music 的歌词（AMLL 核心库）和移植自 Mineradio（GPL-3.0）的粒子特效。
set -euo pipefail

FOLIA_REPO="https://github.com/chthollyphile/folia-major.git"
FOLIA_COMMIT="26c57f9b1b26b402a09e8943171a332215418ce6"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="$ROOT/Tools/FoliaEmbed"
WORK="${FOLIA_WORK:-$ROOT/build/folia-src}"
OUT="$ROOT/Embed/folia"

echo "==> Folia $FOLIA_COMMIT -> $WORK"
if [ ! -d "$WORK/.git" ]; then
    rm -rf "$WORK"
    mkdir -p "$WORK"
    git -C "$WORK" init -q
    git -C "$WORK" remote add origin "$FOLIA_REPO"
fi
git -C "$WORK" fetch -q --depth 1 origin "$FOLIA_COMMIT"
git -C "$WORK" checkout -q --force FETCH_HEAD
git -C "$WORK" clean -qfdx -e node_modules

# 酷狗接口包只给 Electron 主进程用，而且是 GitHub 压缩包依赖，内嵌页面用不到，去掉
node - "$WORK" <<'EOF'
const fs = require('fs');
const path = require('path');
const dir = process.argv[2];
const drop = 'kugoumusicapi';
const pkgPath = path.join(dir, 'package.json');
const pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf8'));
for (const key of ['dependencies', 'devDependencies', 'optionalDependencies']) {
    if (pkg[key]) delete pkg[key][drop];
}
fs.writeFileSync(pkgPath, JSON.stringify(pkg, null, 2) + '\n');
const lockPath = path.join(dir, 'package-lock.json');
const lock = JSON.parse(fs.readFileSync(lockPath, 'utf8'));
const root = lock.packages[''];
for (const key of ['dependencies', 'devDependencies', 'optionalDependencies']) {
    if (root[key]) delete root[key][drop];
}
for (const key of Object.keys(lock.packages)) {
    if (key === `node_modules/${drop}` || key.startsWith(`node_modules/${drop}/`)) delete lock.packages[key];
}
fs.writeFileSync(lockPath, JSON.stringify(lock, null, 2) + '\n');
EOF

cp -R "$HERE/embed" "$WORK/"
cp "$HERE/folia-embed.html" "$HERE/vite.embed.config.ts" "$WORK/"

echo "==> npm ci"
(cd "$WORK" && ELECTRON_SKIP_BINARY_DOWNLOAD=1 npm ci --ignore-scripts --no-audit --no-fund --loglevel=error)

# Apple Music 风格歌词用的 AMLL 核心库（AGPL-3.0）；three.js 用 Folia 自带的版本（Mineradio 特效用）
AMLL_CORE="@applemusic-like-lyrics/core@0.6.0"
echo "==> npm install $AMLL_CORE"
(cd "$WORK" && npm install --no-save --ignore-scripts --no-audit --no-fund --legacy-peer-deps --loglevel=error "$AMLL_CORE")

echo "==> vite build"
(cd "$WORK" && npx vite build --config vite.embed.config.ts --logLevel warn)

rm -rf "$OUT"
mkdir -p "$OUT"
cp -R "$WORK/dist-embed/." "$OUT/"
echo "==> $(du -sh "$OUT" | cut -f1) -> $OUT"
