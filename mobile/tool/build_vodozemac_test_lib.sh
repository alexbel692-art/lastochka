#!/usr/bin/env bash
# Собирает библиотеку vodozemac для компьютера, на котором идут тесты (flutter test запускается не на
# телефоне, поэтому готовой библиотеки для него нет). Исходники — из того же пакета flutter_vodozemac,
# версия зафиксирована в pubspec.lock, зависимости Rust — по Cargo.lock (--locked).
# Печатает строку VODOZEMAC_LIB=<папка> (для $GITHUB_ENV).
set -euo pipefail
cache="${PUB_CACHE:-$HOME/.pub-cache}"
ver=$(awk '/^  flutter_vodozemac:/{f=1} f&&/version:/{gsub(/"/,"",$2);print $2;exit}' pubspec.lock)
src="$cache/hosted/pub.dev/flutter_vodozemac-$ver/rust"
[ -f "$src/Cargo.toml" ] || { echo "нет исходников vodozemac: $src" >&2; exit 1; }
out="$PWD/build/vodozemac-test"
mkdir -p "$out"
CARGO_TARGET_DIR="$out/target" cargo build --release --locked --manifest-path "$src/Cargo.toml" >&2
lib=$(ls "$out"/target/release/libvodozemac_bindings_dart.so)
echo "VODOZEMAC_LIB=$(dirname "$lib")/"
