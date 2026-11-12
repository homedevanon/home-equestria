#!/usr/bin/env bash
# Builds the mouth-shape analyser (SConstruct) for the platforms the game ships on.
#   native/talking_avatar/build.sh [linux|windows|android ...]      (default: all three)
set -euo pipefail
cd "$(dirname "$0")"
GODOT_CPP="${GODOT_CPP:-$HOME/tools/godot-cpp}"
SCONS="${SCONS:-$HOME/tools/scons-venv/bin/scons}"
ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
NDK_VERSION="${NDK_VERSION:-27.1.12297006}"
MINGW="${MINGW:-$HOME/tools/llvm-mingw-20260922-ucrt-ubuntu-22.04-x86_64}"
SCONS_LOCK="${SCONS_LOCK:-$HOME/project/captures/navigation-overhaul-2026-10-02/scons.lock}"
JOBS="${JOBS:-$(( $(nproc) / 2 ))}"

build() { # scons arguments
	GODOT_CPP="$GODOT_CPP" ANDROID_HOME="$ANDROID_HOME" flock "$SCONS_LOCK" nice -n 10 "$SCONS" -j "$JOBS" "$@"
}

# Object files are shared between platforms (src/*.os), so the platforms build one after another.
for platform in "${@:-linux windows android}"; do
	for p in $platform; do
		case "$p" in
		linux)
			build target=template_debug platform=linux
			build target=template_release platform=linux ;;
		windows)
			build target=template_debug platform=windows use_mingw=yes use_llvm=yes "mingw_prefix=$MINGW" arch=x86_64
			build target=template_release platform=windows use_mingw=yes use_llvm=yes "mingw_prefix=$MINGW" arch=x86_64 ;;
		android)
			# The Quest export only uses the release library (talking_avatar.gdextension).
			build target=template_release platform=android arch=arm64 "ndk_version=$NDK_VERSION" ;;
		*) echo "unknown platform $p" >&2; exit 1 ;;
		esac
	done
done
