#!/bin/zsh
set -euo pipefail
project="${0:A:h:h}"
test_dir="$(mktemp -d /private/tmp/launchpad-paging-tests.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT
sources=("$project"/Sources/*.swift)
sources=("${(@)sources:#*/main.swift}")
# 不要加 -module-cache-path：SwiftUI 宏插件在自定义 module cache 下会出现
# "external macro implementation type ... could not be found" 而编译失败。
# -disable-sandbox 让宏插件能正常加载。
swiftc -disable-sandbox -parse-as-library \
  "${sources[@]}" "$project/Tests/PagingInputTests.swift" \
  -o "$test_dir/paging-input-tests"
"$test_dir/paging-input-tests"
