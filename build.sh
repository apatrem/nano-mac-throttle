#!/bin/zsh
set -euo pipefail

cd "${0:A:h}"
mkdir -p .build/module-cache
swiftc -O -framework AppKit -module-cache-path "$PWD/.build/module-cache" nano-mac-throttle.swift -o nano-mac-throttle
echo "Built: $PWD/nano-mac-throttle"
