#!/bin/bash
# Quick Swift syntax check for the PoC sources on Linux.
# SwiftUI/UIKit cannot be compiled here, so we only parse-check:
#   swiftc -parse  validates syntax without resolving imports.
set -e
cd "$(dirname "$0")/.."

if ! command -v swiftc >/dev/null 2>&1; then
    echo "swiftc not found. Install Swift via swiftly:" >&2
    echo "  curl -O https://download.swift.org/swiftly/linux/swiftly-x86_64.tar.gz" >&2
    echo "  tar zxf swiftly-x86_64.tar.gz && ./swiftly/swiftly init" >&2
    exit 1
fi

fail=0
while IFS= read -r file; do
    if swiftc -parse "$file" 2>/tmp/parse.err; then
        echo "OK   $file"
    else
        echo "FAIL $file"
        cat /tmp/parse.err
        fail=1
    fi
done < <(find Nugget include -name '*.swift' | sort)

exit $fail