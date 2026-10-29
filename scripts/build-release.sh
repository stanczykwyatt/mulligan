#!/bin/bash
# Builds release archives of mulligan into ./build.
#
#   scripts/build-release.sh          on a Mac: one universal binary (Apple silicon and Intel),
#                                     packed as mulligan-Darwin-arm64.tar.gz and -x86_64.tar.gz
#   scripts/build-release.sh linux    with Swift's Static Linux SDK installed: fully static
#                                     binaries for x86_64 and aarch64, as mulligan-Linux-*.tar.gz
#
# Each archive holds the binary, the license and the readme, and gets a .sha256 file beside it.
# The names match what `uname -s` and `uname -m` print, so the one-line install can pick one.
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p build
version="$(sed -n 's/^let version = "\(.*\)"$/\1/p' Sources/mulligan/CLI.swift)"

pack() {
	local binary="$1" name="$2"
	local folder
	folder="$(mktemp -d)"
	cp "$binary" "$folder/mulligan"
	cp LICENSE README.md "$folder/"
	tar -czf "build/$name.tar.gz" -C "$folder" mulligan LICENSE README.md
	rm -rf "$folder"
	if command -v sha256sum >/dev/null; then
		(cd build && sha256sum "$name.tar.gz" > "$name.tar.gz.sha256")
	else
		(cd build && shasum -a 256 "$name.tar.gz" > "$name.tar.gz.sha256")
	fi
	echo "build/$name.tar.gz"
}

if [[ "${1:-}" == "linux" ]]; then
	for arch in x86_64 aarch64; do
		swift build -c release --product mulligan --swift-sdk "$arch-swift-linux-musl"
		bin="$(swift build -c release --swift-sdk "$arch-swift-linux-musl" --show-bin-path)"
		strip "$bin/mulligan" 2>/dev/null || true
		pack "$bin/mulligan" "mulligan-Linux-$arch"
	done
	exit 0
fi

# Each architecture is built on its own and then combined, which works with just the
# Command Line Tools.
binaries=()
for arch in arm64 x86_64; do
	triple="$arch-apple-macosx13.0"
	swift build -c release --product mulligan --triple "$triple"
	bin="$(swift build -c release --triple "$triple" --show-bin-path)"
	binaries+=("$bin/mulligan")
done
lipo -create "${binaries[@]}" -output build/mulligan
strip -x build/mulligan
codesign --force --sign - --options runtime build/mulligan
build/mulligan --version | grep -q "$version"
pack build/mulligan mulligan-Darwin-arm64
pack build/mulligan mulligan-Darwin-x86_64
