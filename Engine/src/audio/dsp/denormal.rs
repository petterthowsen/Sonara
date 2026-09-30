//! Flush denormals to zero on the current thread.
//!
//! Filter and delay tails decay into denormal floats, which are many times slower to process on
//! x86 and turn a silent reverb into a CPU spike. The audio callback calls
//! [`flush_denormals_to_zero`] at the top of every block: it is a couple of instructions and
//! survives the backend reusing or swapping its thread.

/// Set flush-to-zero (and denormals-are-zero where the CPU has it) for the calling thread.
#[inline]
pub fn flush_denormals_to_zero() {
    #[cfg(target_arch = "x86_64")]
    // SAFETY: reads and writes this thread's MXCSR; FTZ (bit 15) and DAZ (bit 6) only change how
    // denormal floats are handled.
    unsafe {
        let mut csr: u32 = 0;
        std::arch::asm!("stmxcsr [{}]", in(reg) &mut csr, options(nostack, preserves_flags));
        csr |= 0x8040;
        std::arch::asm!("ldmxcsr [{}]", in(reg) &csr, options(nostack, preserves_flags));
    }
    #[cfg(target_arch = "aarch64")]
    // SAFETY: reads and writes this thread's FPCR; FZ (bit 24) only changes how denormal floats
    // are handled.
    unsafe {
        let mut fpcr: u64;
        std::arch::asm!("mrs {}, fpcr", out(reg) fpcr, options(nomem, nostack, preserves_flags));
        fpcr |= 1 << 24;
        std::arch::asm!("msr fpcr, {}", in(reg) fpcr, options(nomem, nostack, preserves_flags));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    #[cfg(any(target_arch = "x86_64", target_arch = "aarch64"))]
    fn denormal_results_become_zero() {
        // Runs on its own thread so the mode doesn't leak into other tests.
        std::thread::spawn(|| {
            let tiny = std::hint::black_box(f32::MIN_POSITIVE);
            assert!(
                (tiny / 4.0).is_subnormal(),
                "denormals exist before flushing"
            );
            flush_denormals_to_zero();
            let tiny = std::hint::black_box(f32::MIN_POSITIVE);
            assert_eq!(tiny / 4.0, 0.0);
        })
        .join()
        .unwrap();
    }
}
