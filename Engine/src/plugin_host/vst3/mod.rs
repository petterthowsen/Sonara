//! VST3 hosting for the plugin host subprocess (spec 028).
//!
//! Deliberately parallel to the CLAP implementation, not shared with it: the two formats meet
//! only at the few dispatch points later phases add (the plan's ground rules). Phase 1 provides
//! bundle loading, the host-side COM objects, and the standalone `--probe` / `--scan-vst3`
//! paths. Phase 2 adds running instances inside `plugin_host` (`commands`, `processor`).

pub mod commands;
pub mod event_list;
pub mod host_context;
pub mod instance;
pub mod module;
pub mod moduleinfo;
pub mod param_changes;
pub mod params;
pub mod processor;
pub mod scan;
pub mod state_blob;
pub mod stream;

pub use event_list::EventList;
pub use host_context::{ComponentHandler, HostContext, Vst3Shared};
pub use instance::Vst3Instance;
pub use module::Vst3Module;
pub use param_changes::{ParamValueQueue, ParameterChanges};
pub use params::Vst3ParamMap;
pub use processor::Vst3Processor;
pub use scan::ScannedClass;
pub use stream::MemoryStream;

use ::vst3::Steinberg::{char16, TUID};

/// A class ID as spec 028 writes it: the 16 `TUID` bytes as 32 uppercase hex characters.
pub fn tuid_to_hex(id: &TUID) -> String {
    let mut out = String::with_capacity(32);
    for byte in id {
        out.push_str(&format!("{:02X}", *byte as u8));
    }
    out
}

/// Parse a 32 hex character class ID (case-insensitive) into a `TUID`.
pub fn tuid_from_hex(text: &str) -> Option<TUID> {
    let bytes = text.as_bytes();
    if bytes.len() != 32 || !bytes.iter().all(|b| b.is_ascii_hexdigit()) {
        return None;
    }
    let mut id = [0 as std::ffi::c_char; 16];
    for (index, pair) in bytes.chunks(2).enumerate() {
        let hi = (pair[0] as char).to_digit(16)?;
        let lo = (pair[1] as char).to_digit(16)?;
        id[index] = ((hi << 4) | lo) as u8 as std::ffi::c_char;
    }
    Some(id)
}

/// Read a NUL-terminated char8 array (`PClassInfo`-style fields).
pub fn char8_str(bytes: &[std::ffi::c_char]) -> String {
    let len = bytes.iter().position(|b| *b == 0).unwrap_or(bytes.len());
    let raw: &[u8] = unsafe { std::slice::from_raw_parts(bytes.as_ptr() as *const u8, len) };
    String::from_utf8_lossy(raw).into_owned()
}

/// Read a NUL-terminated UTF-16 string (`String128` fields).
pub fn char16_str(chars: &[char16]) -> String {
    let len = chars.iter().position(|c| *c == 0).unwrap_or(chars.len());
    String::from_utf16_lossy(&chars[..len])
}

/// Write `text` into a `String128` (UTF-16, NUL-terminated, truncated to 127 units).
pub fn write_string128(dst: *mut ::vst3::Steinberg::Vst::String128, text: &str) {
    if dst.is_null() {
        return;
    }
    let dst: &mut ::vst3::Steinberg::Vst::String128 = unsafe { &mut *dst };
    let units: Vec<u16> = text.encode_utf16().take(dst.len() - 1).collect();
    for (index, unit) in units.iter().enumerate() {
        dst[index] = *unit;
    }
    for index in units.len()..dst.len() {
        dst[index] = 0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tuid_hex_round_trip() {
        let id: TUID = (0..16)
            .map(|b| b as std::ffi::c_char)
            .collect::<Vec<_>>()
            .try_into()
            .unwrap();
        let hex = tuid_to_hex(&id);
        assert_eq!(hex, "000102030405060708090A0B0C0D0E0F");
        assert_eq!(tuid_from_hex(&hex).unwrap(), id);
        // Case-insensitive.
        assert_eq!(tuid_from_hex(&hex.to_lowercase()).unwrap(), id);
    }

    #[test]
    fn tuid_from_hex_rejects_bad_input() {
        assert!(tuid_from_hex("").is_none());
        assert!(tuid_from_hex("00").is_none());
        assert!(tuid_from_hex(&"0".repeat(31)).is_none());
        assert!(tuid_from_hex(&"0".repeat(33)).is_none());
        assert!(tuid_from_hex(&"G".repeat(32)).is_none());
    }

    #[test]
    fn string_helpers() {
        let mut string128 = [0u16; 128];
        write_string128(&mut string128, "Sonara");
        assert_eq!(char16_str(&string128), "Sonara");
        let long: String = "x".repeat(500);
        write_string128(&mut string128, &long);
        assert_eq!(char16_str(&string128).len(), 127);
    }
}
