/// SIMD-optimized audio buffer mixing utilities
///
/// These functions use platform-specific SIMD instructions (AVX, SSE, NEON)
/// to accelerate common audio operations.

#[cfg(target_arch = "x86_64")]
use std::arch::x86_64::*;

#[cfg(target_arch = "aarch64")]
use std::arch::aarch64::*;

/// Mix two audio buffers together: output[i] += input[i]
///
/// Uses SIMD instructions when available (AVX, SSE, NEON) for ~4-8x speedup.
/// Falls back to scalar code on unsupported platforms.
#[inline]
pub fn mix_blocks(output: &mut [f32], input: &[f32]) {
    let len = output.len().min(input.len());

    #[cfg(target_arch = "x86_64")]
    {
        if is_x86_feature_detected!("avx") {
            unsafe {
                mix_blocks_avx(output, input, len);
            }
            return;
        }
        if is_x86_feature_detected!("sse") {
            unsafe {
                mix_blocks_sse(output, input, len);
            }
            return;
        }
    }

    #[cfg(target_arch = "aarch64")]
    {
        if std::arch::is_aarch64_feature_detected!("neon") {
            unsafe {
                mix_blocks_neon(output, input, len);
            }
            return;
        }
    }

    // Fallback: scalar version
    for i in 0..len {
        output[i] += input[i];
    }
}

// x86_64 AVX implementation (8 samples at once)
#[cfg(target_arch = "x86_64")]
#[target_feature(enable = "avx")]
unsafe fn mix_blocks_avx(output: &mut [f32], input: &[f32], len: usize) {
    let mut i = 0;

    // Process 8 samples at a time with AVX
    while i + 8 <= len {
        let out = _mm256_loadu_ps(output.as_ptr().add(i));
        let inp = _mm256_loadu_ps(input.as_ptr().add(i));
        let result = _mm256_add_ps(out, inp);
        _mm256_storeu_ps(output.as_mut_ptr().add(i), result);
        i += 8;
    }

    // Scalar tail for remaining samples
    while i < len {
        *output.get_unchecked_mut(i) += *input.get_unchecked(i);
        i += 1;
    }
}

// x86_64 SSE implementation (4 samples at once)
#[cfg(target_arch = "x86_64")]
#[target_feature(enable = "sse")]
unsafe fn mix_blocks_sse(output: &mut [f32], input: &[f32], len: usize) {
    let mut i = 0;

    // Process 4 samples at a time with SSE
    while i + 4 <= len {
        let out = _mm_loadu_ps(output.as_ptr().add(i));
        let inp = _mm_loadu_ps(input.as_ptr().add(i));
        let result = _mm_add_ps(out, inp);
        _mm_storeu_ps(output.as_mut_ptr().add(i), result);
        i += 4;
    }

    // Scalar tail for remaining samples
    while i < len {
        *output.get_unchecked_mut(i) += *input.get_unchecked(i);
        i += 1;
    }
}

// ARM NEON implementation (4 samples at once)
#[cfg(target_arch = "aarch64")]
#[target_feature(enable = "neon")]
unsafe fn mix_blocks_neon(output: &mut [f32], input: &[f32], len: usize) {
    let mut i = 0;

    // Process 4 samples at a time with NEON
    while i + 4 <= len {
        let out = vld1q_f32(output.as_ptr().add(i));
        let inp = vld1q_f32(input.as_ptr().add(i));
        let result = vaddq_f32(out, inp);
        vst1q_f32(output.as_mut_ptr().add(i), result);
        i += 4;
    }

    // Scalar tail for remaining samples
    while i < len {
        *output.get_unchecked_mut(i) += *input.get_unchecked(i);
        i += 1;
    }
}

