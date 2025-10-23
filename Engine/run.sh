#!/bin/bash
# Run the DAW audio engine

cd "$(dirname "$0")"

echo "Building and running DAW Audio Engine..."
cargo run --release
