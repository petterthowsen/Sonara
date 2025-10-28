#!/bin/bash
# Quick test script for sfizz integration
# Usage: ./test_sfizz.sh /path/to/your/file.sfz

SFZ_FILE="${1:-test_kick.sfz}"

echo "Testing sfizz integration with: $SFZ_FILE"
echo ""

# Check if engine is running
if ! pgrep -x "engine" > /dev/null; then
    echo "Error: Engine not running. Start it with ./run.sh first."
    exit 1
fi

echo "Step 1: Creating channel 2 (SFZ Channel)"
oscsend localhost 7000 /channel/create i 2 s "SFZ Channel"
sleep 0.1

echo "Step 2: Adding sfizz device to channel 2, position 0"
oscsend localhost 7000 /channel/2/add_device s "sonara.builtin.sfizz" i 0 i 1 i 1
sleep 0.1

echo "Step 3: Loading SFZ file: $SFZ_FILE"
oscsend localhost 7000 /channel/2/device/0/load_file s "$SFZ_FILE"
sleep 0.5

echo ""
echo "✅ Sfizz device configured!"
echo ""
echo "Next steps to test audio:"
echo "  1. Create a track: oscsend localhost 7000 /track/create i 1 i 2"
echo "  2. Create a clip and add MIDI notes (see test_osc.sh for examples)"
echo "  3. Create clip instances on the track"
echo "  4. Start playback: oscsend localhost 7000 /transport/play"
echo ""
echo "Check engine logs for SFZ loading status."
