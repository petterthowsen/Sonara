//! Minimal futex helpers for the plugin block handshake.
//!
//! Linux futexes operate on a `u32` in shared memory. The engine rings a host's doorbell after
//! publishing a block; the host rings it back when the block is done. Both sides re-check their
//! sequence number after waking, so a lost wakeup only costs another loop iteration.

use std::sync::atomic::{AtomicU32, Ordering};
use std::time::Duration;

/// Ring `count` waiters on `word`. `i32::MAX` wakes everyone, which is what both sides want:
/// the engine and the host may both wait on the same doorbell.
pub fn wake(word: &AtomicU32, count: i32) {
    // SAFETY: `word` lives in shared memory that outlives its owner; the syscall only reads the
    // address as a futex key.
    unsafe {
        libc::syscall(
            libc::SYS_futex,
            word as *const AtomicU32 as *const u32,
            libc::FUTEX_WAKE,
            count as libc::c_long,
            0 as *const libc::timespec,
            0 as *const u32,
            0 as libc::c_long,
        );
    }
}

/// Wait while `word` still holds `expected`, up to `timeout`. Returns immediately (`EAGAIN`) when
/// the value already changed, which closes the lost-wakeup window.
pub fn wait(word: &AtomicU32, expected: u32, timeout: Option<Duration>) {
    let timespec = timeout.map(|d| libc::timespec {
        tv_sec: d.as_secs() as libc::time_t,
        tv_nsec: d.subsec_nanos() as libc::c_long,
    });
    let timespec_ptr = timespec
        .as_ref()
        .map_or(std::ptr::null(), |t| t as *const libc::timespec);

    // SAFETY: see `wake`; `timespec` outlives the call.
    unsafe {
        libc::syscall(
            libc::SYS_futex,
            word as *const AtomicU32 as *const u32,
            libc::FUTEX_WAIT,
            expected as libc::c_long,
            timespec_ptr,
            0 as *const u32,
            0 as libc::c_long,
        );
    }
}

/// Bump `word` and wake the other side. Used whenever a side publishes work the other may wait
/// for.
pub fn ring(word: &AtomicU32) {
    word.fetch_add(1, Ordering::AcqRel);
    wake(word, i32::MAX);
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use std::thread;
    use std::time::Instant;

    #[test]
    fn wait_returns_after_a_ring() {
        let word = Arc::new(AtomicU32::new(0));
        let waiter = {
            let word = Arc::clone(&word);
            thread::spawn(move || {
                let expected = word.load(Ordering::Acquire);
                // Value hasn't changed yet, so this blocks until the ring arrives.
                wait(&word, expected, Some(Duration::from_secs(5)));
            })
        };
        thread::sleep(Duration::from_millis(20));
        ring(&word);
        waiter.join().unwrap();
    }

    #[test]
    fn wait_misses_a_changed_value_instead_of_blocking() {
        let word = AtomicU32::new(7);
        let started = Instant::now();
        wait(&word, 6, Some(Duration::from_secs(5)));
        assert!(started.elapsed() < Duration::from_millis(500));
    }
}
