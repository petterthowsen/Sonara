#!/bin/bash
# Build and run the Sonara audio engine in debug mode (slow; expect audio glitches)

cd "$(dirname "$0")" || exit 1

echo "🔨 Building Sonara Audio Engine (Debug)..."
# Build all binaries: the engine spawns plugin_host from its own directory for CLAP plugins
cargo build --bins || exit 1

echo ""
echo "🚀 Starting Sonara Audio Engine (Debug)..."
echo "   (Listening on OSC port 7000, sending to port 7001)"
echo ""

# Run from Engine/ so logs land in Engine/logs/
RUST_LOG=engine=info,warn exec ./target/debug/engine "$@"
