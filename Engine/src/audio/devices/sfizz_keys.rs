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
    fn plain_sfz_has_no_key_info() {
        let mut synth = sfizz::Synth::new().expect("synth");
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/test_kick.sfz");
        synth.load_sfz(path).expect("load kick");
        assert!(read_key_info(&mut synth).is_empty());
    }
}
