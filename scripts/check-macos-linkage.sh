#!/bin/bash
# check-macos-linkage.sh — gate: a macOS llama-server archive must only depend on
# system libraries and dylibs bundled next to the binary.
#
# Usage: check-macos-linkage.sh <dir containing llama-server and lib*.dylib>
# Prints `otool -L` for llama-server and every bundled dylib; exits 1 on any
# dependency outside /usr/lib, /System, @loader_path/ or an @rpath/ name that is
# bundled in the same directory. /opt/homebrew and /usr/local always fail.
set -uo pipefail
DIR="${1:?dir}"
fail=0
shopt -s nullglob
files=("$DIR/llama-server" "$DIR"/*.dylib)
[ -f "$DIR/llama-server" ] || { echo "❌ no llama-server in $DIR"; exit 1; }

for f in "${files[@]}"; do
    echo "── otool -L $(basename "$f")"
    otool -L "$f"
    # tail +2: first line is the file path; for dylibs the next line is its own
    # install name (id), which is not a dependency.
    skip=2; [ "${f##*.}" = "dylib" ] && skip=3
    while read -r dep; do
        [ -z "$dep" ] && continue
        case "$dep" in
            /opt/homebrew/*|/usr/local/*) echo "❌ FORBIDDEN dependency in $(basename "$f"): $dep"; fail=1 ;;
            /usr/lib/*|/System/*) ;;
            @loader_path/*) [ -f "$DIR/${dep#@loader_path/}" ] || { echo "❌ not bundled: $dep"; fail=1; } ;;
            @rpath/*) [ -f "$DIR/${dep#@rpath/}" ] || { echo "❌ @rpath dep not bundled: $dep"; fail=1; } ;;
            *) echo "❌ UNEXPECTED dependency in $(basename "$f"): $dep"; fail=1 ;;
        esac
    done < <(otool -L "$f" | tail -n +"$skip" | awk '{print $1}')
    # RPATH entries must not point at the build machine either.
    while read -r rp; do
        case "$rp" in
            @loader_path|@loader_path/*|@executable_path|@executable_path/*) ;;
            "") ;;
            *) echo "❌ suspicious LC_RPATH in $(basename "$f"): $rp"; fail=1 ;;
        esac
    done < <(otool -l "$f" | awk '/LC_RPATH/{r=1} r&&/ path /{print $2; r=0}')
done
[ $fail -eq 0 ] && echo "✅ linkage check passed" || echo "❌ linkage check FAILED"
exit $fail
