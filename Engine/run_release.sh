#!/bin/bash
# Build and run the Sonara audio engine in release mode (optimized)

cd "$(dirname "$0")" || exit 1

echo "🔨 Building Sonara Audio Engine (Release Mode - Optimized)..."
# Build all binaries: the engine spawns plugin_host from its own directory for CLAP plugins.
# SONARA_FEATURES adds cargo features, e.g. SONARA_FEATURES=rt-debug for the allocation checker.
cargo build --release --bins ${SONARA_FEATURES:+--features "$SONARA_FEATURES"} || exit 1

echo ""
echo "🚀 Starting Sonara Audio Engine (Release)..."
echo "   (Listening on OSC port 7000, sending to port 7001)"
echo ""

# Run from Engine/ so logs land in Engine/logs/
RUST_LOG=engine=info,warn exec ./target/release/engine "$@"
