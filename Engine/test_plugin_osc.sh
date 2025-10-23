#!/bin/bash
# Test script for CLAP plugin OSC commands
# Usage: ./test_plugin_osc.sh

HOST="127.0.0.1"
PORT=7000

echo "Testing CLAP Plugin OSC Commands"
echo "=================================="
echo ""

# Function to send OSC message using oscsend (from liblo-tools)
send_osc() {
    local address=$1
    shift
    echo "→ Sending: $address $@"
    oscsend $HOST $PORT $address "$@"
    sleep 0.1
}

# Check if oscsend is installed
if ! command -v oscsend &> /dev/null; then
    echo "Error: oscsend not found. Please install liblo-tools:"
    echo "  sudo apt-get install liblo-tools"
    exit 1
fi

echo "=== 1. Initialize Project ==="
send_osc /project/init fff 120.0 4 4 960 48000

echo ""
echo "=== 2. Create Master Channel ==="
send_osc /channel/1/create s "Master"

echo ""
echo "=== 3. Create Test Channel ==="
send_osc /channel/2/create s "Test Channel"

echo ""
echo "=== 4. Scan for CLAP Plugins ==="
send_osc /plugin/scan
echo "   Waiting for scan to complete..."
sleep 2

echo ""
echo "=== 5. Check Scan Results ==="
echo "   (Check engine logs for discovered plugins)"
echo "   Expected OSC response:"
echo "     /plugin/scan_complete [count]"

echo ""
echo "=== 6. Load Plugin - ACTIVE and ENABLED (default) ==="
echo "   Using /channel/2/add_device with active=1, enabled=1"
send_osc /channel/2/add_device siii "michaelwillis.dragonfly.room" -1 1 1
sleep 0.5

echo ""
echo "=== 6b. Load Another Plugin - INACTIVE (save RAM) ==="
echo "   Using /channel/2/add_device with active=0, enabled=1"
send_osc /channel/2/add_device siii "com.airwindows.consolidated" -1 0 1
echo "   (Plugin loaded but not activated - minimal RAM usage)"
sleep 0.5

echo ""
echo "=== 7. Query Plugin Parameters ==="
send_osc /plugin/get_parameters ii 2 0
echo "   Expected OSC responses:"
echo "     /plugin/param/count [channel_id, device_position, count]"
echo "     /plugin/param/info [channel_id, device_pos, param_id, name, min, max, default]"
sleep 0.5

echo ""
echo "=== 8. Set Plugin Parameter (same as built-in devices!) ==="
send_osc /channel/2/device/0/param/0 f 0.75
echo "   Set parameter 0 to 75%"

echo ""
echo "=== 8b. Test Bypass (Enabled/Disabled) ==="
send_osc /channel/2/device/0/enable i 0
echo "   Device 0 disabled (bypassed) - audio passes through unprocessed"
sleep 0.3
send_osc /channel/2/device/0/enable i 1
echo "   Device 0 enabled (back on)"

echo ""
echo "=== 8c. Test Activation (Active/Inactive) ==="
send_osc /channel/2/device/1/activate i 1
echo "   Device 1 (Airwindows) activated - loading buffers..."
sleep 0.5
send_osc /channel/2/device/1/activate i 0
echo "   Device 1 deactivated - freeing RAM"

echo ""
echo "=== 9. Save Plugin State ==="
send_osc /plugin/state/save ii 2 0
echo "   Expected OSC response:"
echo "     /plugin/state/saved [channel_id, device_position, state_base64]"

echo ""
echo "=== 10. Load Plugin State (example) ==="
echo "   /plugin/state/load [2, 0, \"base64encodedstate\"]"
echo "   (Skipped - requires saved state from step 9)"

echo ""
echo "=================================="
echo "Test sequence complete!"
echo ""
echo "Key Takeaways:"
echo "  • Plugins use /channel/{id}/add_device (same as built-in devices!)"
echo "  • Optional active/enabled parameters: add_device [id, pos, active?, enabled?]"
echo "  • Active=0: Plugin not loaded (saves RAM for large templates)"
echo "  • Enabled=0: Plugin bypassed (zero-latency, maintains state)"
echo "  • Parameters work the same: /channel/{id}/device/{pos}/param/{id}"
echo "  • State management is plugin-specific: /plugin/state/save and /plugin/state/load"
echo ""
echo "To monitor responses, run in another terminal:"
echo "  oscdump 7001"
echo ""
echo "To scan for installed plugins:"
echo "  ls -la /usr/lib/clap"
echo "  ls -la ~/.clap"
echo ""
echo "Check engine logs for detailed output:"
echo "  tail -f Engine/logs/engine.log | grep -i plugin"

