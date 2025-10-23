#!/bin/bash
# Helper script to run the audio engine

cd Engine
echo "Building and running DAW Audio Engine..."
echo ""
cargo run --release
