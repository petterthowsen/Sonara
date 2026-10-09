//! The single `Vec<u8>` the engine stores for a VST3 plugin's state (spec 028 decisions).
//!
//! VST3 has two state streams, one from the component and one from the controller. They are
//! packed as `b"SVST3\0\0\x01"`, then `u32 LE` length and bytes of the component state, then
//! `u32 LE` length and bytes of the controller state. Unpacking never panics: a truncated
//! blob, a foreign blob (a CLAP state, say) or one with trailing bytes is an error.

/// Magic and version at the start of every VST3 state blob.
pub const MAGIC: &[u8; 8] = b"SVST3\0\0\x01";

pub fn pack(component: &[u8], controller: &[u8]) -> Vec<u8> {
    let mut blob = Vec::with_capacity(MAGIC.len() + 8 + component.len() + controller.len());
    blob.extend_from_slice(MAGIC);
    blob.extend_from_slice(&(component.len() as u32).to_le_bytes());
    blob.extend_from_slice(component);
    blob.extend_from_slice(&(controller.len() as u32).to_le_bytes());
    blob.extend_from_slice(controller);
    blob
}

/// Split a blob into `(component, controller)` state bytes.
pub fn unpack(blob: &[u8]) -> Result<(&[u8], &[u8]), String> {
    let rest = blob
        .strip_prefix(MAGIC.as_slice())
        .ok_or_else(|| "not a VST3 state blob (bad magic or version)".to_string())?;
    let (component, rest) = take_chunk(rest, "component")?;
    let (controller, rest) = take_chunk(rest, "controller")?;
    if !rest.is_empty() {
        return Err(format!(
            "VST3 state blob has {} trailing byte(s)",
            rest.len()
        ));
    }
    Ok((component, controller))
}

fn take_chunk<'a>(bytes: &'a [u8], what: &str) -> Result<(&'a [u8], &'a [u8]), String> {
    let (len, rest) = bytes
        .split_first_chunk::<4>()
        .ok_or_else(|| format!("VST3 state blob is truncated before the {what} length"))?;
    let len = u32::from_le_bytes(*len) as usize;
    if rest.len() < len {
        return Err(format!(
            "VST3 state blob is truncated: {what} state needs {len} bytes, {} left",
            rest.len()
        ));
    }
    Ok(rest.split_at(len))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_both_streams() {
        let blob = pack(b"component", b"ctl");
        assert_eq!(unpack(&blob).unwrap(), (&b"component"[..], &b"ctl"[..]));
    }

    #[test]
    fn empty_streams_round_trip() {
        let blob = pack(&[], &[]);
        assert_eq!(unpack(&blob).unwrap(), (&[][..], &[][..]));
    }

    #[test]
    fn every_truncation_is_an_error() {
        let blob = pack(b"component", b"controller");
        for len in 0..blob.len() {
            assert!(unpack(&blob[..len]).is_err(), "prefix of {len} bytes");
        }
    }

    #[test]
    fn foreign_and_oversized_blobs_are_errors() {
        assert!(unpack(b"").is_err());
        assert!(unpack(b"CLAP state, definitely not ours").is_err());
        // A length that points far past the end must not allocate or panic.
        let mut blob = MAGIC.to_vec();
        blob.extend_from_slice(&u32::MAX.to_le_bytes());
        assert!(unpack(&blob).is_err());
        // Trailing bytes.
        let mut blob = pack(b"a", b"b");
        blob.push(0);
        assert!(unpack(&blob).is_err());
        // A different version byte.
        let mut blob = pack(b"a", b"b");
        blob[7] = 2;
        assert!(unpack(&blob).is_err());
    }
}
