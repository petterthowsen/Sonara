//! Key labels and keyswitches declared by a loaded SFZ (`label_keyN`, `sw_last` / `sw_label`).
//!
//! sfizz only exposes key labels through the C API. Keyswitch slots and their labels are only
//! reachable through its OSC-style message interface, so this module sends the query messages and
//! collects the replies.
//!
//! Not real-time safe: call it from the SFZ load thread, before the synth is shared with the
//! audio thread.

use std::ffi::{c_char, c_int, c_void, CStr, CString};

/// Whether a labeled key plays sound or switches articulation.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum KeyKind {
    Playable,
    Keyswitch,
}

/// One key the SFZ names or uses as a keyswitch.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct KeyInfo {
    pub key: u8,
    /// Empty for a keyswitch with no `sw_label`.
    pub label: String,
    pub kind: KeyKind,
}

/// A reply from the synth, decoded into the shapes we query.
#[derive(Debug)]
enum Reply {
    Blob(Vec<u8>),
    Text(String),
    Ints(Vec<i32>),
    Float(f32),
    Other,
}

/// Collects replies. Lives on the caller's stack for the duration of one `query`.
struct Sink(Vec<Reply>);

unsafe extern "C" fn on_reply(
    data: *mut c_void,
    _delay: c_int,
    _path: *const c_char,
    sig: *const c_char,
    args: *const sfizz::sfizz_arg_t,
) {
    // SAFETY: `data` is the `Sink` passed to `sfizz_create_client`, alive for the whole query.
    let sink = unsafe { &mut *(data as *mut Sink) };
    let sig = if sig.is_null() {
        ""
    } else {
        unsafe { CStr::from_ptr(sig) }.to_str().unwrap_or("")
    };
    let reply = match sig.as_bytes().first() {
        Some(b'b') if !args.is_null() => {
            let blob = unsafe { (*args).b };
            if blob.is_null() {
                Reply::Other
            } else {
                let blob = unsafe { &*blob };
                if blob.data.is_null() {
                    Reply::Blob(Vec::new())
                } else {
                    Reply::Blob(unsafe {
                        std::slice::from_raw_parts(blob.data, blob.size as usize).to_vec()
                    })
                }
            }
        }
        Some(b's') if !args.is_null() => {
            let s = unsafe { (*args).s };
            if s.is_null() {
                Reply::Other
            } else {
                Reply::Text(unsafe { CStr::from_ptr(s) }.to_string_lossy().into_owned())
            }
        }
        // sfizz replies integers as `i` (int32) or `h` (int64) depending on the property.
        Some(b'i' | b'h') if !args.is_null() && sig.bytes().all(|c| c == b'i' || c == b'h') => {
            Reply::Ints(
                sig.bytes()
                    .enumerate()
                    .map(|(n, c)| unsafe {
                        let arg = *args.add(n);
                        if c == b'h' {
                            arg.h as i32
                        } else {
                            arg.i
                        }
                    })
                    .collect(),
            )
        }
        Some(b'f') if !args.is_null() => Reply::Float(unsafe { (*args).f }),
        _ => Reply::Other,
    };
    sink.0.push(reply);
}

/// Send a no-argument query and return the first reply, if any.
fn query(synth: &mut sfizz::Synth, path: &str) -> Option<Reply> {
    let path = CString::new(path).ok()?;
    let sig = CString::new("").ok()?;
    let mut sink = Sink(Vec::new());
    // SAFETY: the client is deleted before `sink` goes out of scope, and sfizz delivers replies
    // synchronously from within `sfizz_send_message`.
    unsafe {
        let client = sfizz::sfizz_create_client(&mut sink as *mut Sink as *mut c_void);
        if client.is_null() {
            return None;
        }
        sfizz::sfizz_set_receive_callback(client, Some(on_reply));
        sfizz::sfizz_send_message(
            synth.as_raw(),
            client,
            0,
            path.as_ptr(),
            sig.as_ptr(),
            std::ptr::null(),
        );
        sfizz::sfizz_delete_client(client);
    }
    sink.0.into_iter().next()
}

/// The normalized 0–1 value the loaded SFZ gives a CC with `set_ccN` / `set_hdccN`. Without one,
/// this is sfizz's built-in default: 0, except CC7 (MIDI 100), CC10 (0.5) and CC11 (1.0).
pub fn read_cc_default(synth: &mut sfizz::Synth, cc_number: u8) -> Option<f32> {
    match query(synth, &format!("/cc{cc_number}/default")) {
        Some(Reply::Float(value)) => Some(value),
        _ => None,
    }
}

/// Every CC the loaded SFZ uses or labels, named when it has a `label_ccN` and `CC{n}` otherwise.
///
/// Replaces `sfizz::Synth::cc_labels`: the C API hands out a `c_str()` of a temporary vector, so
/// the binding reads freed memory and returns garbage names. The query interface copies the text.
pub fn read_cc_labels(synth: &mut sfizz::Synth) -> Vec<sfizz::CcLabel> {
    let Some(Reply::Blob(bits)) = query(synth, "/cc/slots") else {
        return Vec::new();
    };
    (0u8..128)
        .filter(|&cc| {
            bits.get(cc as usize / 8)
                .is_some_and(|b| b & (1 << (cc % 8)) != 0)
        })
        .filter_map(|cc| {
            let label = match query(synth, &format!("/cc{cc}/label")) {
                Some(Reply::Text(text)) => text,
                _ => String::new(),
            };
            // sfizz labels CC7/10/11 itself; those and unlabeled CCs are not "named by the file".
            Some(sfizz::CcLabel {
                cc_number: cc,
                name: if label.is_empty() {
                    format!("CC{cc}")
                } else {
                    label
                },
            })
        })
        .collect()
}

/// Keys the SFZ labels with `label_keyN`.
fn key_labels(synth: &mut sfizz::Synth) -> Vec<(u8, String)> {
    let raw = synth.as_raw();
    // SAFETY: `raw` is a live synth; returned strings are valid until the next sfizz call and are
    // copied immediately.
    let count = unsafe { sfizz::sfizz_get_num_key_labels(raw) };
    let mut labels = Vec::with_capacity(count as usize);
    for index in 0..count as c_int {
        let key = unsafe { sfizz::sfizz_get_key_label_number(raw, index) };
        let text = unsafe { sfizz::sfizz_get_key_label_text(raw, index) };
        if !(0..=127).contains(&key) || text.is_null() {
            continue;
        }
        let text = unsafe { CStr::from_ptr(text) }
            .to_string_lossy()
            .into_owned();
        labels.push((key as u8, text));
    }
    labels
}

/// Keys used as `sw_last` keyswitches, from sfizz's 128-bit slot set (LSB-first bytes).
fn keyswitch_keys(synth: &mut sfizz::Synth) -> Vec<u8> {
    let Some(Reply::Blob(bits)) = query(synth, "/sw/last/slots") else {
        return Vec::new();
    };
    (0u8..128)
        .filter(|&k| {
            bits.get(k as usize / 8)
                .is_some_and(|b| b & (1 << (k % 8)) != 0)
        })
        .collect()
}

fn keyswitch_label(synth: &mut sfizz::Synth, key: u8) -> String {
    match query(synth, &format!("/sw/last/{key}/label")) {
        Some(Reply::Text(text)) => text,
        _ => String::new(),
    }
}

/// Keys the SFZ's regions can play: the union of every region's `key_range`, merged into sorted,
/// non-overlapping inclusive `(lo, hi)` ranges. Keyswitch keys are not region keys, so they are
/// not included. Empty when the SFZ has no regions.
pub fn read_playable_ranges(synth: &mut sfizz::Synth) -> Vec<(u8, u8)> {
    let count = match query(synth, "/num_regions") {
        Some(Reply::Ints(v)) => v.first().copied().unwrap_or(0),
        _ => 0,
    };
    let mut ranges = Vec::new();
    for region in 0..count.max(0) {
        if let Some(Reply::Ints(v)) = query(synth, &format!("/region{region}/key_range")) {
            if let [lo, hi, ..] = v[..] {
                // A disabled region (`key=-1`) has a negative or inverted range.
                if lo >= 0 && lo <= hi {
                    ranges.push((lo.min(127) as u8, hi.min(127) as u8));
                }
            }
        }
    }
    merge_ranges(ranges)
}

/// Sort and merge overlapping or touching inclusive ranges.
fn merge_ranges(mut ranges: Vec<(u8, u8)>) -> Vec<(u8, u8)> {
    ranges.sort_unstable();
    let mut merged: Vec<(u8, u8)> = Vec::with_capacity(ranges.len());
    for (lo, hi) in ranges {
        match merged.last_mut() {
            Some(last) if lo as u16 <= last.1 as u16 + 1 => last.1 = last.1.max(hi),
            _ => merged.push((lo, hi)),
        }
    }
    merged
}

/// Everything the loaded SFZ names or switches, sorted by key. A key that is both labeled and a
/// keyswitch is reported as a keyswitch.
pub fn read_key_info(synth: &mut sfizz::Synth) -> Vec<KeyInfo> {
    let mut by_key: std::collections::BTreeMap<u8, KeyInfo> = key_labels(synth)
        .into_iter()
        .map(|(key, label)| {
            (
                key,
                KeyInfo {
                    key,
                    label,
                    kind: KeyKind::Playable,
                },
            )
        })
        .collect();
    for key in keyswitch_keys(synth) {
        let label = keyswitch_label(synth, key);
        by_key.insert(
            key,
            KeyInfo {
                key,
                label,
                kind: KeyKind::Keyswitch,
            },
        );
    }
    by_key.into_values().collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn load_fixture() -> sfizz::Synth {
        let mut synth = sfizz::Synth::new().expect("synth");
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/test_keyswitch.sfz");
        synth.load_sfz(path).expect("load fixture");
        synth
    }

    #[test]
    fn key_info_reads_labels_and_keyswitches() {
        let mut synth = load_fixture();
        let info = read_key_info(&mut synth);
        eprintln!("{info:#?}");
        let get = |k: u8| info.iter().find(|i| i.key == k);

        assert_eq!(
            get(60).map(|i| (i.label.as_str(), i.kind)),
            Some(("Open", KeyKind::Playable))
        );
        assert_eq!(
            get(62).map(|i| (i.label.as_str(), i.kind)),
            Some(("Muted", KeyKind::Playable))
        );
        assert_eq!(
            get(24).map(|i| (i.label.as_str(), i.kind)),
            Some(("Sustain", KeyKind::Keyswitch))
        );
        assert_eq!(
            get(25).map(|i| (i.label.as_str(), i.kind)),
            Some(("Staccato", KeyKind::Keyswitch))
        );
        assert_eq!(
            get(27).map(|i| (i.label.as_str(), i.kind)),
            Some(("Trill", KeyKind::Keyswitch))
        );
        assert_eq!(
            get(29).map(|i| (i.label.as_str(), i.kind)),
            Some(("", KeyKind::Keyswitch))
        );
    }

    #[test]
    fn playable_ranges_merge_regions() {
        let mut synth = load_fixture();
        // Regions play keys 60 and 62 only: two ranges with a gap, keyswitches excluded.
        assert_eq!(read_playable_ranges(&mut synth), vec![(60, 60), (62, 62)]);
    }

    #[test]
    fn merge_ranges_joins_overlapping_and_touching() {
        assert_eq!(
            merge_ranges(vec![(48, 60), (36, 47), (55, 70), (80, 90)]),
            vec![(36, 70), (80, 90)]
        );
        assert!(merge_ranges(vec![]).is_empty());
    }

    #[test]
    fn plain_sfz_has_no_key_info() {
        let mut synth = sfizz::Synth::new().expect("synth");
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/test_kick.sfz");
        synth.load_sfz(path).expect("load kick");
        assert!(read_key_info(&mut synth).is_empty());
        // The kick plays its one key.
        assert_eq!(read_playable_ranges(&mut synth), vec![(36, 36)]);
    }
}
