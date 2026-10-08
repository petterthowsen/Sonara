//! Argument helpers shared by the route files.

use rosc::OscType;

/// An integer arg; Godot may send ints as `h` or `f` depending on how they were built.
pub(super) fn osc_int(arg: &OscType) -> Option<i64> {
    match arg {
        OscType::Int(i) => Some(*i as i64),
        OscType::Long(l) => Some(*l),
        OscType::Float(f) => Some(*f as i64),
        _ => None,
    }
}

pub(super) fn osc_float(arg: &OscType) -> Option<f32> {
    match arg {
        OscType::Float(f) => Some(*f),
        OscType::Double(d) => Some(*d as f32),
        OscType::Int(i) => Some(*i as f32),
        OscType::Long(l) => Some(*l as f32),
        _ => None,
    }
}

/// OSC type tags of `args` separated by spaces (`"i i f"`), for warnings.
pub(super) fn osc_arg_types(args: &[OscType]) -> String {
    args.iter()
        .map(|arg| match arg {
            OscType::Int(_) => "i",
            OscType::Float(_) => "f",
            OscType::String(_) => "s",
            OscType::Blob(_) => "b",
            OscType::Long(_) => "h",
            OscType::Double(_) => "d",
            OscType::Bool(true) => "T",
            OscType::Bool(false) => "F",
            _ => "?",
        })
        .collect::<Vec<_>>()
        .join(" ")
}

/// Fixtures shared by the OSC tests.
#[cfg(test)]
pub(super) mod test_support {
    use rosc::OscType;

    /// An OSC string argument.
    pub(in crate::osc) fn string(s: &str) -> OscType {
        OscType::String(s.to_string())
    }
}
