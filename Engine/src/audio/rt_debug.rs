//! Audio-thread allocation checker, enabled with `--features rt-debug`.
//!
//! `check_callback` wraps the audio callback body in `assert_no_alloc`, whose global allocator
//! (installed in `main.rs`) counts every (de)allocation made inside it. The crate only counts per
//! thread, so `section` attributes violations to a named region of the callback. `report` logs the
//! totals from outside the checked region, where logging may allocate.
//!
//! Without the feature every function here is a plain passthrough.

#[cfg(feature = "rt-debug")]
mod imp {
    use std::cell::Cell;
    use tracing::warn;

    const MAX_SECTIONS: usize = 32;

    thread_local! {
        /// (section name, violations since the last report). Const-initialized so first access
        /// from the audio thread doesn't allocate.
        static SECTIONS: Cell<[(&'static str, u32); MAX_SECTIONS]> =
            const { Cell::new([("", 0); MAX_SECTIONS]) };
        static TOTAL: Cell<u64> = const { Cell::new(0) };
        /// Running count of violations recorded by any section (for nesting).
        static ATTRIBUTED: Cell<u32> = const { Cell::new(0) };
    }

    pub fn check_callback<T>(f: impl FnOnce() -> T) -> T {
        assert_no_alloc::assert_no_alloc(|| section("callback (unattributed)", f))
    }

    pub fn section<T>(name: &'static str, f: impl FnOnce() -> T) -> T {
        let before = assert_no_alloc::violation_count();
        let attributed_before = ATTRIBUTED.with(|a| a.get());
        let result = f();
        // Violations a nested section already recorded belong to it, not to this one.
        let raw = assert_no_alloc::violation_count().wrapping_sub(before);
        let nested = ATTRIBUTED.with(|a| a.get()).wrapping_sub(attributed_before);
        let own = raw.saturating_sub(nested);
        if own > 0 {
            record(name, own);
        }
        result
    }

    fn record(name: &'static str, count: u32) {
        TOTAL.with(|t| t.set(t.get() + count as u64));
        ATTRIBUTED.with(|a| a.set(a.get().wrapping_add(count)));
        SECTIONS.with(|cell| {
            let mut table = cell.get();
            let slot = table
                .iter()
                .position(|(n, _)| *n == name)
                .or_else(|| table.iter().position(|(n, _)| n.is_empty()));
            if let Some(i) = slot {
                table[i] = (name, table[i].1 + count);
            }
            cell.set(table);
        });
    }

    /// Log and clear the violations counted since the last call. Call outside `check_callback`.
    pub fn report() {
        let table = SECTIONS.with(|cell| cell.replace([("", 0); MAX_SECTIONS]));
        let entries: Vec<String> = table
            .iter()
            .filter(|(name, count)| !name.is_empty() && *count > 0)
            .map(|(name, count)| format!("{name}: {count}"))
            .collect();
        if !entries.is_empty() {
            warn!(
                "rt-debug: audio thread (de)allocations since last report ({} total): {}",
                TOTAL.with(|t| t.get()),
                entries.join(", ")
            );
        }
    }
}

#[cfg(not(feature = "rt-debug"))]
mod imp {
    #[inline(always)]
    pub fn check_callback<T>(f: impl FnOnce() -> T) -> T {
        f()
    }

    #[inline(always)]
    pub fn section<T>(_name: &'static str, f: impl FnOnce() -> T) -> T {
        f()
    }

    #[inline(always)]
    pub fn report() {}
}

pub use imp::{check_callback, report, section};
