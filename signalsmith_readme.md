# Signalsmith DSP

A Rust port of the Signalsmith DSP C++ library, providing various DSP (Digital Signal Processing) algorithms for audio and signal processing. This library implements the same high-quality algorithms as the original C++ library, optimized for Rust performance and ergonomics.

[![Crates.io](https://img.shields.io/crates/v/signalsmith-dsp)](https://crates.io/crates/signalsmith-dsp) [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## [](https://crates.io/crates/signalsmith-dsp#features)Features

-   **FFT**: Fast Fourier Transform implementation optimized for sizes that are products of 2^a \* 3^b, with both complex and real-valued implementations
-   **Filters**: Biquad filters with various configurations (lowpass, highpass, bandpass, etc.) and design methods (Butterworth, cookbook)
-   **Delay Lines**: Efficient delay line implementation with multiple interpolation methods (nearest, linear, cubic)
-   **Curves**: Cubic curve interpolation with control over slope and curvature
-   **Windows**: Window functions for spectral processing (Hann, Hamming, Kaiser, Blackman-Harris, etc.)
-   **Envelopes**: LFOs and envelope generators with precise control and minimal aliasing
-   **Spectral Processing**: Tools for spectral manipulation, phase vocoding, and frequency-domain operations
-   **Time Stretching**: High-quality time stretching and pitch shifting using phase vocoder techniques
-   **STFT**: Short-time Fourier transform implementation with overlap-add processing
-   **Mixing Utilities**: Multi-channel mixing matrices and stereo-to-multi-channel conversion
-   **Linear Algebra**: Expression template system for efficient vector operations
-   **no\_std Support**: Can be used in environments without the standard library, with optional `alloc` feature
-   **Spacing (Room Reverb)**: Simulate room acoustics with customizable geometry, early reflections, and multi-channel output

## [](https://crates.io/crates/signalsmith-dsp#installation)Installation

Add this to your `Cargo.toml`:

    [dependencies]
    signalsmith-dsp = "0.0.1"
    

## [](https://crates.io/crates/signalsmith-dsp#usage-examples)Usage Examples

### [](https://crates.io/crates/signalsmith-dsp#fft-example)FFT Example

    use signalsmith_dsp::fft::{SimpleFFT, SimpleRealFFT};
    use num_complex::Complex;
    
    fn fft_example() {
        // Create a new FFT instance for size 1024
        let fft = SimpleFFT::<f32>::new(1024);
    
        // Input and output buffers
        let mut time_domain = vec![Complex::new(0.0, 0.0); 1024];
        let mut freq_domain = vec![Complex::new(0.0, 0.0); 1024];
    
        // Fill input with a sine wave
        for i in 0..1024 {
            time_domain[i] = Complex::new((i as f32 * 0.1).sin(), 0.0);
        }
    
        // Perform forward FFT
        fft.fft(&time_domain, &mut freq_domain);
    
        // Process in frequency domain if needed
    
        // Perform inverse FFT
        fft.ifft(&freq_domain, &mut time_domain);
    }
    

### [](https://crates.io/crates/signalsmith-dsp#biquad-filter-example)Biquad Filter Example

    use signalsmith_dsp::filters::{Biquad, BiquadDesign, FilterType};
    
    fn filter_example() {
        // Create a new biquad filter
        let mut filter = Biquad::<f32>::new(true);
    
        // Configure as a lowpass filter at 1000 Hz with Q=0.7 (assuming 44.1 kHz sample rate)
        filter.lowpass(1000.0 / 44100.0, 0.7, BiquadDesign::Cookbook);
    
        // Process a buffer of audio
        let mut audio_buffer = vec![0.0; 1024];
        // Fill buffer with audio data...
    
        // Apply the filter
        filter.process_buffer(&mut audio_buffer);
    }
    

### [](https://crates.io/crates/signalsmith-dsp#delay-line-example)Delay Line Example

    use signalsmith_dsp::delay::{Delay, InterpolatorCubic};
    
    fn delay_example() {
        // Create a delay line with cubic interpolation and 1 second capacity at 44.1 kHz
        let mut delay = Delay::new(InterpolatorCubic::<f32>::new(), 44100);
    
        // Process audio
        let mut output = 0.0;
        for _ in 0..1000 {
            let input = 0.5; // Replace with your input sample
    
            // Read from the delay line (500 ms delay)
            output = delay.read(22050.0);
    
            // Write to the delay line
            delay.write(input);
    
            // Use output...
        }
    }
    

### [](https://crates.io/crates/signalsmith-dsp#time-stretching-and-pitch-shifting-example)Time Stretching and Pitch Shifting Example

    use signalsmith_dsp::stretch::SignalsmithStretch;
    
    fn time_stretch_example() {
        // Create a new stretch processor
        let mut stretcher = SignalsmithStretch::<f32>::new();
    
        // Configure for 2x time stretching with pitch shift up 3 semitones
        stretcher.configure(1, 1024, 256, false); // 1 channel, 1024 block size, 256 interval
        stretcher.set_transpose_semitones(3.0, 0.5); // Pitch up 3 semitones
        stretcher.set_formant_semitones(1.0, false); // Formant shift
    
        // Input and output buffers
        let input_len = 1024;
        let output_len = 2048; // 2x longer output
        let input = vec![vec![0.0; input_len]]; // Fill with audio data
        let mut output = vec![vec![0.0; output_len]];
    
        // Process the audio
        stretcher.process(&input, input_len, &mut output, output_len);
    }
    

### [](https://crates.io/crates/signalsmith-dsp#multichannel-mixing-example)Multichannel Mixing Example

    use signalsmith_dsp::mix::{Hadamard, StereoMultiMixer};
    
    fn mixing_example() {
        // Create a Hadamard matrix for 4-channel mixing
        let hadamard = Hadamard::<f32>::new(4);
    
        // Mix 4 channels in-place
        let mut data = vec![1.0, 2.0, 3.0, 4.0];
        hadamard.in_place(&mut data);
        // data now contains orthogonal mix of input channels
    
        // Create a stereo-to-multichannel mixer (must be even number of channels)
        let mixer = StereoMultiMixer::<f32>::new(6);
    
        // Convert stereo to 6 channels
        let stereo_input = [0.5, 0.8];
        let mut multi_output = vec![0.0; 6];
        mixer.stereo_to_multi(&stereo_input, &mut multi_output);
    
        // Convert back to stereo
        let mut stereo_output = [0.0, 0.0];
        mixer.multi_to_stereo(&multi_output, &mut stereo_output);
    
        // Apply energy-preserving crossfade
        let mut to_coeff = 0.0;
        let mut from_coeff = 0.0;
        signalsmith_dsp::mix::cheap_energy_crossfade(0.3, &mut to_coeff, &mut from_coeff);
        // Use coefficients for crossfading between signals
    }
    

### [](https://crates.io/crates/signalsmith-dsp#spacing-room-reverb-example)Spacing (Room Reverb) Example

    use signalsmith_dsp::spacing::{Spacing, Position};
    
    fn spacing_example() {
        // Create a new Spacing effect with a given sample rate
        let mut spacing = Spacing::<f32>::new(48000.0);
        // Add source and receiver positions (in meters)
        let src = spacing.add_source(Position { x: 0.0, y: 0.0, z: 0.0 });
        let recv = spacing.add_receiver(Position { x: 3.43, y: 0.0, z: 0.0 });
        // Add a direct path
        spacing.add_path(src, recv, 1.0, 0.0);
        // Prepare input and output buffers
        let mut input = vec![0.0; 500];
        input[0] = 1.0; // Impulse
        let mut outputs = vec![vec![0.0; 500]];
        // Process the input through the effect
        spacing.process(&[&input], &mut outputs);
        // outputs[0] now contains the processed signal
    }
    

## [](https://crates.io/crates/signalsmith-dsp#advanced-usage)Advanced Usage

For more advanced usage examples, see the examples directory:

-   [FFT Example](https://github.com/CuteDSP/RSSignalsmithDSP/blob/HEAD/examples/fft_example.rs) - Fast Fourier Transform
-   [Filter Example](https://github.com/CuteDSP/RSSignalsmithDSP/blob/HEAD/examples/filter_example.rs) - Biquad filters
-   [Delay Example](https://github.com/CuteDSP/RSSignalsmithDSP/blob/HEAD/examples/delay_example.rs) - Delay lines
-   [STFT Example](https://github.com/CuteDSP/RSSignalsmithDSP/blob/HEAD/examples/stft_example.rs) - Short-time Fourier transform
-   [Stretch Example](https://github.com/CuteDSP/RSSignalsmithDSP/blob/HEAD/examples/stretch_example.rs) - Time stretching and pitch shifting
-   [Curves Example](https://github.com/CuteDSP/RSSignalsmithDSP/blob/HEAD/examples/curves_example.rs) - Curve interpolation
-   [Envelopes Example](https://github.com/CuteDSP/RSSignalsmithDSP/blob/HEAD/examples/envelopes_example.rs) - LFOs and envelope generators
-   [Linear Example](https://github.com/CuteDSP/RSSignalsmithDSP/blob/HEAD/examples/linear_example.rs) - Linear operations
-   [Mix Example](https://github.com/CuteDSP/RSSignalsmithDSP/blob/HEAD/examples/mix_example.rs) - Audio mixing utilities
-   [Performance Example](https://github.com/CuteDSP/RSSignalsmithDSP/blob/HEAD/examples/perf_example.rs) - Performance optimizations
-   [Rates Example](https://github.com/CuteDSP/RSSignalsmithDSP/blob/HEAD/examples/rates_example.rs) - Sample rate conversion
-   [Spectral Example](https://github.com/CuteDSP/RSSignalsmithDSP/blob/HEAD/examples/spectral_example.rs) - Spectral processing
-   [Windows Example](https://github.com/CuteDSP/RSSignalsmithDSP/blob/HEAD/examples/windows_example.rs) - Window functions

## [](https://crates.io/crates/signalsmith-dsp#module-overview)Module Overview

### [](https://crates.io/crates/signalsmith-dsp#fft-fft-module)FFT (`fft` module)

Provides Fast Fourier Transform implementations optimized for different use cases:

-   `SimpleFFT`: General purpose complex-to-complex FFT
-   `SimpleRealFFT`: Optimized for real-valued inputs
-   Support for non-power-of-2 sizes (factorizable into 2^a × 3^b)

### [](https://crates.io/crates/signalsmith-dsp#filters-filters-module)Filters (`filters` module)

Digital filter implementations:

-   `Biquad`: Second-order filter section with various design methods
-   Various filter types: lowpass, highpass, bandpass, notch, peaking, etc.
-   Support for filter cascading and multi-channel processing

### [](https://crates.io/crates/signalsmith-dsp#delay-delay-module)Delay (`delay` module)

Delay line utilities:

-   Various interpolation methods (nearest, linear, cubic)
-   Single and multi-channel delay lines
-   Buffer abstractions for efficient memory usage

### [](https://crates.io/crates/signalsmith-dsp#spectral-processing-spectral-module)Spectral Processing (`spectral` module)

Frequency-domain processing tools:

-   Magnitude/phase conversion utilities
-   Phase vocoder techniques for pitch and time manipulation
-   Frequency-domain filtering and manipulation

### [](https://crates.io/crates/signalsmith-dsp#stft-stft-module)STFT (`stft` module)

Short-time Fourier transform processing:

-   Overlap-add processing framework
-   Window function application
-   Spectral processing utilities

### [](https://crates.io/crates/signalsmith-dsp#stretch-stretch-module)Stretch (`stretch` module)

Time stretching and pitch shifting:

-   High-quality phase vocoder implementation using `SignalsmithStretch`
-   Independent control of time and pitch
-   Formant preservation and frequency mapping
-   Real-time processing capabilities

### [](https://crates.io/crates/signalsmith-dsp#mix-mix-module)Mix (`mix` module)

Multichannel mixing utilities:

-   Orthogonal matrices (Hadamard, Householder) for efficient mixing
-   Stereo to multichannel conversion
-   Energy-preserving crossfading

### [](https://crates.io/crates/signalsmith-dsp#windows-windows-module)Windows (`windows` module)

Window functions for spectral processing:

-   Common window types (Hann, Hamming, Kaiser, etc.)
-   Window design utilities
-   Overlap handling and perfect reconstruction

### [](https://crates.io/crates/signalsmith-dsp#envelopes-envelopes-module)Envelopes (`envelopes` module)

Low-frequency oscillators and envelope generators:

-   Precise control with minimal aliasing
-   Multiple waveform types
-   Configurable frequency and amplitude

### [](https://crates.io/crates/signalsmith-dsp#linear-linear-module)Linear (`linear` module)

Linear algebra utilities:

-   Expression template system for efficient vector operations
-   Optimized mathematical operations

### [](https://crates.io/crates/signalsmith-dsp#curves-curves-module)Curves (`curves` module)

Curve interpolation:

-   Cubic curve interpolation with control over slope and curvature
-   Smooth parameter transitions

### [](https://crates.io/crates/signalsmith-dsp#rates-rates-module)Rates (`rates` module)

Sample rate conversion:

-   High-quality resampling algorithms
-   Configurable quality settings

### [](https://crates.io/crates/signalsmith-dsp#spacing-spacing-module)Spacing (`spacing` module)

Provides a customizable room reverb effect:

-   Multi-tap delay network simulating early reflections
-   3D source and receiver positioning
-   Adjustable room size, damping, diffusion, bass, decay, and cross-mix
-   Suitable for spatial audio and immersive effects

## [](https://crates.io/crates/signalsmith-dsp#feature-flags)Feature Flags

-   `std` (default): Use the Rust standard library
-   `alloc`: Enable allocation without std (for no\_std environments)

## [](https://crates.io/crates/signalsmith-dsp#performance)Performance

This library is designed with performance in mind and offers several optimizations:

-   **SIMD Opportunities**: Code structure allows for SIMD optimizations where applicable
-   **Cache-Friendly Algorithms**: Algorithms are designed to minimize cache misses
-   **Minimal Allocations**: Operations avoid allocations during processing
-   **Trade-offs**: Where appropriate, there are options to trade between quality and performance

For maximum performance:

-   Use the largest practical buffer sizes for batch processing
-   Reuse processor instances rather than creating new ones
-   Consider using the `f32` type for most audio applications unless higher precision is needed
-   Review the examples in `examples/perf_example.rs` for performance-critical applications

## [](https://crates.io/crates/signalsmith-dsp#license)License

This project is licensed under the MIT License - see the LICENSE file for details.

## [](https://crates.io/crates/signalsmith-dsp#acknowledgments)Acknowledgments

-   Original C++ library: [Signalsmith Audio DSP Library](https://github.com/signalsmith-audio/dsp)
-   Signalsmith Audio's excellent [technical blog](https://signalsmith-audio.co.uk/writing/) with in-depth explanations of DSP concepts
-   The comprehensive [design documentation](https://signalsmith-audio.co.uk/code/stretch/) for the time stretching algorithm