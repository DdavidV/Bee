#!/bin/sh
# Installs what the tests need, on a machine that can build Bee (Elixir,
# Node.js, git – see ../README.md): Bee's own dependencies, Playwright and
# its Chromium, and – when the system lacks them – the two libraries
# Chromium needs that Bee's requirements don't bring (libnss3, libnspr4),
# unpacked into ./libs (no sudo; playwright.config.mjs puts them on
# LD_LIBRARY_PATH). Run it once; again after updating Bee does no harm.
set -eu
cd "$(dirname "$0")"

# Bee itself: a run builds its release from this checkout.
(cd .. && mix setup)
if [ -f ../assets/package.json ] && [ ! -d ../assets/node_modules ]; then
  npm install --prefix ../assets
fi

npm install
npx playwright install chromium

# Debian and Ubuntu (also WSL) without Chromium's libraries: unpacked here.
# Elsewhere: `npx playwright install-deps chromium` (asks for sudo).
if command -v ldconfig >/dev/null 2>&1 && ! ldconfig -p | grep -q libnss3.so; then
  if command -v apt-get >/dev/null 2>&1 && command -v dpkg-deb >/dev/null 2>&1; then
    echo "libnss3 isn't installed: unpacking it into ./libs"
    mkdir -p libs
    (cd libs && apt-get download libnss3 libnspr4 && for deb in *.deb; do dpkg-deb -x "$deb" root; done)
  else
    echo "Chromium needs libnss3: install it, or run: npx playwright install-deps chromium"
  fi
fi

echo "Ready: npm test"
