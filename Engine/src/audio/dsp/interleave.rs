//! SIMD stereo interleaving: planar L/R buffers to and from interleaved LR frames.

#[cfg(target_arch = "x86_64")]
use std::arch::x86_64::*;

#[cfg(target_arch = "aarch64")]
use std::arch::aarch64::*;

/// SIMD-optimized stereo interleaving: L[0], L[1], L[2]... + R[0], R[1], R[2]... → LR[0], LR[1], LR[2], LR[3]...
#[inline]
pub(crate) fn interleave_stereo(left: &[f32], right: &[f32], output: &mut [f32]) {
    let frames = left.len().min(right.len());
    debug_assert_eq!(output.len(), frames * 2);

    #[cfg(target_arch = "x86_64")]
    {
        if is_x86_feature_detected!("avx") {
            unsafe {
                interleave_stereo_avx(left, right, output, frames);
            }
            return;
        }
        if is_x86_feature_detected!("sse") {
            unsafe {
                interleave_stereo_sse(left, right, output, frames);
            }
            return;
        }
    }

    #[cfg(target_arch = "aarch64")]
    {
        if std::arch::is_aarch64_feature_detected!("neon") {
            unsafe {
                interleave_stereo_neon(left, right, output, frames);
            }
            return;
        }
    }

    // Fallback: scalar
    for i in 0..frames {
        output[i * 2] = left[i];
        output[i * 2 + 1] = right[i];
    }
}

/// SIMD-optimized stereo de-interleaving: LR[0], LR[1], LR[2], LR[3]... → L[0], L[1]... + R[0], R[1]...
#[inline]
pub(crate) fn deinterleave_stereo(input: &[f32], left: &mut [f32], right: &mut [f32]) {
    let frames = left.len().min(right.len());
    debug_assert_eq!(input.len(), frames * 2);

    #[cfg(target_arch = "x86_64")]
    {
        if is_x86_feature_detected!("avx") {
            unsafe {
                deinterleave_stereo_avx(input, left, right, frames);
            }
            return;
        }
        if is_x86_feature_detected!("sse") {
            unsafe {
                deinterleave_stereo_sse(input, left, right, frames);
            }
            return;
        }
    }

    #[cfg(target_arch = "aarch64")]
    {
        if std::arch::is_aarch64_feature_detected!("neon") {
            unsafe {
                deinterleave_stereo_neon(input, left, right, frames);
            }
            return;
        }
    }

    // Fallback: scalar
    for i in 0..frames {
        left[i] = input[i * 2];
        right[i] = input[i * 2 + 1];
    }
}

// x86_64 AVX implementations
#[cfg(target_arch = "x86_64")]
#[target_feature(enable = "avx")]
unsafe fn interleave_stereo_avx(left: &[f32], right: &[f32], output: &mut [f32], frames: usize) {
    let mut i = 0;
    // Process 8 frames at a time (8 L + 8 R → 16 interleaved)
    while i + 8 <= frames {
        let l = _mm256_loadu_ps(left.as_ptr().add(i));
        let r = _mm256_loadu_ps(right.as_ptr().add(i));

        // Unpack low/high to interleave
        let lr_low = _mm256_unpacklo_ps(l, r); // L0 R0 L1 R1 | L4 R4 L5 R5
        let lr_high = _mm256_unpackhi_ps(l, r); // L2 R2 L3 R3 | L6 R6 L7 R7

        // Permute to get correct order: L0 R0 L1 R1 L2 R2 L3 R3 | L4 R4 L5 R5 L6 R6 L7 R7
        let interleaved_low = _mm256_permute2f128_ps(lr_low, lr_high, 0x20);
        let interleaved_high = _mm256_permute2f128_ps(lr_low, lr_high, 0x31);

        _mm256_storeu_ps(output.as_mut_ptr().add(i * 2), interleaved_low);
        _mm256_storeu_ps(output.as_mut_ptr().add(i * 2 + 8), interleaved_high);

        i += 8;
    }

    // Scalar tail
    while i < frames {
        *output.get_unchecked_mut(i * 2) = *left.get_unchecked(i);
        *output.get_unchecked_mut(i * 2 + 1) = *right.get_unchecked(i);
        i += 1;
    }
}

#[cfg(target_arch = "x86_64")]
#[target_feature(enable = "avx")]
unsafe fn deinterleave_stereo_avx(
    input: &[f32],
    left: &mut [f32],
    right: &mut [f32],
    frames: usize,
) {
    let mut i = 0;
    // Process 8 frames at a time (16 interleaved → 8 L + 8 R)
    while i + 8 <= frames {
        let interleaved_low = _mm256_loadu_ps(input.as_ptr().add(i * 2));
        let interleaved_high = _mm256_loadu_ps(input.as_ptr().add(i * 2 + 8));

        // Permute to group L and R channels
        let lr_low = _mm256_permute2f128_ps(interleaved_low, interleaved_high, 0x20);
        let lr_high = _mm256_permute2f128_ps(interleaved_low, interleaved_high, 0x31);

        // Shuffle to separate L and R
        let l = _mm256_shuffle_ps(lr_low, lr_high, 0b10001000); // Select L channels
        let r = _mm256_shuffle_ps(lr_low, lr_high, 0b11011101); // Select R channels

        _mm256_storeu_ps(left.as_mut_ptr().add(i), l);
        _mm256_storeu_ps(right.as_mut_ptr().add(i), r);

        i += 8;
    }

    // Scalar tail
    while i < frames {
        *left.get_unchecked_mut(i) = *input.get_unchecked(i * 2);
        *right.get_unchecked_mut(i) = *input.get_unchecked(i * 2 + 1);
        i += 1;
    }
}

// x86_64 SSE implementations
#[cfg(target_arch = "x86_64")]
#[target_feature(enable = "sse")]
unsafe fn interleave_stereo_sse(left: &[f32], right: &[f32], output: &mut [f32], frames: usize) {
    let mut i = 0;
    // Process 4 frames at a time (4 L + 4 R → 8 interleaved)
    while i + 4 <= frames {
        let l = _mm_loadu_ps(left.as_ptr().add(i));
        let r = _mm_loadu_ps(right.as_ptr().add(i));

        let lr_low = _mm_unpacklo_ps(l, r); // L0 R0 L1 R1
        let lr_high = _mm_unpackhi_ps(l, r); // L2 R2 L3 R3

        _mm_storeu_ps(output.as_mut_ptr().add(i * 2), lr_low);
        _mm_storeu_ps(output.as_mut_ptr().add(i * 2 + 4), lr_high);

        i += 4;
    }

    // Scalar tail
    while i < frames {
        *output.get_unchecked_mut(i * 2) = *left.get_unchecked(i);
        *output.get_unchecked_mut(i * 2 + 1) = *right.get_unchecked(i);
        i += 1;
    }
}

#[cfg(target_arch = "x86_64")]
#[target_feature(enable = "sse")]
unsafe fn deinterleave_stereo_sse(
    input: &[f32],
    left: &mut [f32],
    right: &mut [f32],
    frames: usize,
) {
    let mut i = 0;
    // Process 4 frames at a time (8 interleaved → 4 L + 4 R)
    while i + 4 <= frames {
        let interleaved_low = _mm_loadu_ps(input.as_ptr().add(i * 2));
        let interleaved_high = _mm_loadu_ps(input.as_ptr().add(i * 2 + 4));

        // Shuffle to separate L and R: select indices 0,2,4,6 for L and 1,3,5,7 for R
        let l = _mm_shuffle_ps(interleaved_low, interleaved_high, 0b10001000); // L0 L1 L2 L3
        let r = _mm_shuffle_ps(interleaved_low, interleaved_high, 0b11011101); // R0 R1 R2 R3

        _mm_storeu_ps(left.as_mut_ptr().add(i), l);
        _mm_storeu_ps(right.as_mut_ptr().add(i), r);

        i += 4;
    }

    // Scalar tail
    while i < frames {
        *left.get_unchecked_mut(i) = *input.get_unchecked(i * 2);
        *right.get_unchecked_mut(i) = *input.get_unchecked(i * 2 + 1);
        i += 1;
    }
}

// ARM NEON implementations
#[cfg(target_arch = "aarch64")]
#[target_feature(enable = "neon")]
unsafe fn interleave_stereo_neon(left: &[f32], right: &[f32], output: &mut [f32], frames: usize) {
    let mut i = 0;
    // Process 4 frames at a time
    while i + 4 <= frames {
        let l = vld1q_f32(left.as_ptr().add(i));
        let r = vld1q_f32(right.as_ptr().add(i));

        // Interleave using zip
        let interleaved = float32x4x2_t(l, r);
        vst2q_f32(output.as_mut_ptr().add(i * 2), interleaved);

        i += 4;
    }

    // Scalar tail
    while i < frames {
        *output.get_unchecked_mut(i * 2) = *left.get_unchecked(i);
        *output.get_unchecked_mut(i * 2 + 1) = *right.get_unchecked(i);
        i += 1;
    }
}

#[cfg(target_arch = "aarch64")]
#[target_feature(enable = "neon")]
unsafe fn deinterleave_stereo_neon(
    input: &[f32],
    left: &mut [f32],
    right: &mut [f32],
    frames: usize,
) {
    let mut i = 0;
    // Process 4 frames at a time
    while i + 4 <= frames {
        let interleaved = vld2q_f32(input.as_ptr().add(i * 2));

        vst1q_f32(left.as_mut_ptr().add(i), interleaved.0);
        vst1q_f32(right.as_mut_ptr().add(i), interleaved.1);

        i += 4;
    }

    // Scalar tail
    while i < frames {
        *left.get_unchecked_mut(i) = *input.get_unchecked(i * 2);
        *right.get_unchecked_mut(i) = *input.get_unchecked(i * 2 + 1);
        i += 1;
    }
}
