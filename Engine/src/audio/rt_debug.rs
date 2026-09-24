//! Audio-thread allocation checker, enabled with `--features rt-debug`.
//!
//! `check_callback` wraps the audio callback body in `assert_no_alloc`, whose global allocator
//! (installed in `main.rs`) counts every (de)allocation made inside it. The crate only counts per
//! thread, so `section` attributes violations to a named region of the callback, and
//! `device_section` to one device (by its id). `report` logs the totals from outside the checked
//! region, where logging may allocate.
//!
//! Without the feature every function here is a plain passthrough.

#[cfg(feature = "rt-debug")]
mod imp {
    use std::cell::Cell;
    use tracing::{info, warn};

    const MAX_SECTIONS: usize = 32;

    /// Bytes of a device id kept in a section name (longer ids are cut off).
    const MAX_DEVICE_ID: usize = 48;

    /// A section name: a static label plus an optional device id, copied inline so building one
    /// on the audio thread doesn't allocate.
    #[derive(Clone, Copy, PartialEq, Eq)]
    pub struct SectionName {
        label: &'static str,
        device_id: [u8; MAX_DEVICE_ID],
        device_id_len: u8,
    }

    impl SectionName {
        const EMPTY: Self = Self {
            label: "",
            device_id: [0; MAX_DEVICE_ID],
            device_id_len: 0,
        };

        fn label(label: &'static str) -> Self {
            Self {
                label,
                ..Self::EMPTY
            }
        }

        fn is_empty(&self) -> bool {
            self.label.is_empty()
        }

        fn display(&self) -> String {
            if self.device_id_len == 0 {
                return self.label.to_string();
            }
            let id = String::from_utf8_lossy(&self.device_id[..self.device_id_len as usize]);
            format!("{} [{}]", self.label, id)
        }
    }

    thread_local! {
        /// (section name, violations since the last report). Const-initialized so first access
        /// from the audio thread doesn't allocate.
        static SECTIONS: Cell<[(SectionName, u32); MAX_SECTIONS]> =
            const { Cell::new([(SectionName::EMPTY, 0); MAX_SECTIONS]) };
        static TOTAL: Cell<u64> = const { Cell::new(0) };
        /// Running count of violations recorded by any section (for nesting).
        static ATTRIBUTED: Cell<u32> = const { Cell::new(0) };
        /// `report` calls and `TOTAL` at the last summary line (None before the first report).
        static SUMMARY: Cell<Option<(u32, u64)>> = const { Cell::new(None) };
    }

    pub fn check_callback<T>(f: impl FnOnce() -> T) -> T {
        assert_no_alloc::assert_no_alloc(|| section("callback (unattributed)", f))
    }

    pub fn section<T>(label: &'static str, f: impl FnOnce() -> T) -> T {
        named_section(SectionName::label(label), f)
    }

    /// Name for `device_section`. Take it before borrowing the device mutably.
    pub fn device_name(label: &'static str, device_id: &str) -> SectionName {
        let bytes = device_id.as_bytes();
        let len = bytes.len().min(MAX_DEVICE_ID);
        let mut name = SectionName::label(label);
        name.device_id[..len].copy_from_slice(&bytes[..len]);
        name.device_id_len = len as u8;
        name
    }

    pub fn device_section<T>(name: SectionName, f: impl FnOnce() -> T) -> T {
        named_section(name, f)
    }

    fn named_section<T>(name: SectionName, f: impl FnOnce() -> T) -> T {
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

    fn record(name: SectionName, count: u32) {
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

    /// `report` calls (2 Hz) between summary lines: one per minute.
    const REPORTS_PER_SUMMARY: u32 = 120;

    /// Log and clear the violations counted since the last call, plus a summary line every
    /// minute that also confirms zero. Call outside `check_callback`.
    pub fn report() {
        let total = TOTAL.with(|t| t.get());
        match SUMMARY.with(|s| s.get()) {
            None => {
                info!("rt-debug: audio thread allocation checker is active");
                SUMMARY.with(|s| s.set(Some((0, total))));
            }
            Some((reports, total_at_summary)) if reports + 1 >= REPORTS_PER_SUMMARY => {
                info!(
                    "rt-debug: {} audio thread (de)allocations in the last minute ({} since start)",
                    total - total_at_summary,
                    total
                );
                SUMMARY.with(|s| s.set(Some((0, total))));
            }
            Some((reports, total_at_summary)) => {
                SUMMARY.with(|s| s.set(Some((reports + 1, total_at_summary))));
            }
        }

        let table = SECTIONS.with(|cell| cell.replace([(SectionName::EMPTY, 0); MAX_SECTIONS]));
        let entries: Vec<String> = table
            .iter()
            .filter(|(name, count)| !name.is_empty() && *count > 0)
            .map(|(name, count)| format!("{}: {}", name.display(), count))
            .collect();
        if !entries.is_empty() {
            warn!(
                "rt-debug: audio thread (de)allocations since last report ({} total): {}",
                total,
                entries.join(", ")
            );
        }
    }
}

#[cfg(not(feature = "rt-debug"))]
mod imp {
    /// Placeholder: without the feature a section name carries nothing.
    #[derive(Clone, Copy)]
    pub struct SectionName;

    #[inline(always)]
    pub fn check_callback<T>(f: impl FnOnce() -> T) -> T {
        f()
    }

    #[inline(always)]
    pub fn section<T>(_label: &'static str, f: impl FnOnce() -> T) -> T {
        f()
    }

    #[inline(always)]
    pub fn device_name(_label: &'static str, _device_id: &str) -> SectionName {
        SectionName
    }

    #[inline(always)]
    pub fn device_section<T>(_name: SectionName, f: impl FnOnce() -> T) -> T {
        f()
    }

    #[inline(always)]
    pub fn report() {}
}

pub use imp::{check_callback, device_name, device_section, report, section, SectionName};
