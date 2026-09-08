#!/usr/bin/env bash

set -e

target="${1:-release}"

export ARCHS='arm64 x86_64'
export BUILD_UNIVERSAL=1

export SQUIRREL_BUNDLED_RECIPES='
  lotem/rime-octagram-data
  lotem/rime-octagram-data@hant
'

# preinstall
./action-install.sh

# build dependencies
# make deps

# build Squirrel
if [ "$target" = "dmg" ]; then
  # SquirrelVoice 分发包：arm64 DMG（卷内含 安装/重装/卸载 .command），无需签名
  make release
  make dmg
else
  make "${target}"
fi

echo 'Packages:'
find package releases -type f \( -name '*.pkg' -o -name '*.zip' -o -name '*.dmg' \) 2>/dev/null
