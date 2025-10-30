#!/bin/bash
# Build and run the Sonara audio engine in release mode (optimized)

cd "$(dirname "$0")"

echo "🔨 Building Sonara Audio Engine (Release Mode - Optimized)..."
cargo build --release --bin engine || exit 1

echo ""
echo "🚀 Starting Sonara Audio Engine (Release)..."
echo "   (Listening on OSC port 7000, sending to port 7001)"
echo ""

# Run with RUST_LOG for better logging
RUST_LOG=engine=info,warn cargo run --release --bin engine

