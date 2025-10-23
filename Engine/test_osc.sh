#!/bin/bash
# Test script for the audio engine using oscsend
# Install oscsend: sudo apt install liblo-tools

echo "Testing DAW Audio Engine OSC interface..."
echo "Make sure the engine is running in another terminal!"
echo ""

sleep 1

echo "1. Starting playback..."
oscsend localhost 7000 /sine/start
sleep 1

echo "2. Setting frequency to 440 Hz (A4)..."
oscsend localhost 7000 /sine/frequency f 440.0
sleep 2

echo "3. Setting frequency to 523.25 Hz (C5)..."
oscsend localhost 7000 /sine/frequency f 523.25
sleep 2

echo "4. Setting frequency to 659.25 Hz (E5)..."
oscsend localhost 7000 /sine/frequency f 659.25
sleep 2

echo "5. Setting amplitude to 0.3..."
oscsend localhost 7000 /sine/amplitude f 0.3
sleep 2

echo "6. Setting frequency to 880 Hz (A5)..."
oscsend localhost 7000 /sine/frequency f 880.0
sleep 2

echo "7. Stopping playback..."
oscsend localhost 7000 /sine/stop

echo ""
echo "Test complete!"
