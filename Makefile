# windoz — convenience targets that wrap the exact scripts CI runs.
# CI stays authoritative: .github/workflows/build-ipa.yml.
#
# Order matters (see the workflow): LLVM -> llvm-mingw -> VC runtime ->
# runtime chain -> app -> IPA. Everything runs on macOS with Xcode 26;
# `make ipa` assumes a clean recursive clone.

SHELL := /bin/bash

.PHONY: all llvm mingw vcruntime runtime app ipa entitlements clean

all: ipa

# LLVM built for iOS (cached in CI; ~25 min cold, seconds warm).
llvm:
	./scripts/build-llvm.sh

# The pinned llvm-mingw release (hash-verified).
mingw:
	./scripts/fetch-llvm-mingw.sh

# Microsoft's VC++ x64 runtime DLLs (hash-pinned release asset).
vcruntime:
	./scripts/fetch-vcruntime.sh

# Wine (ARM64EC), wineserver, FEX (iOS + arm64ec), DXMT, Wine Mono,
# the native D3D12 core, stubs, licence staging.
runtime:
	./scripts/build-runtime.sh

# The app: XcodeGen regenerates Windoz.xcodeproj, then xcodebuild (Debug,
# unsigned) builds it into app-windoz/build/derived.
app:
	./scripts/build-windoz-app.sh

# Payload/Windoz.app -> windoz.ipa (unsigned, ready for sideloading).
ipa: llvm mingw vcruntime runtime app
	./scripts/assemble-ipa.sh

# Verify the committed signing entitlements match the generator.
entitlements:
	./scripts/generate-entitlements.sh --check

clean:
	rm -rf build app-windoz/build
