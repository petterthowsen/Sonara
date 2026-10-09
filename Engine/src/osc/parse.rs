//! Argument helpers shared by the route files: the typed argument reader `Args`, path segment
//! parsing and the lenient number readers.

use rosc::OscType;
use std::fmt;
use std::str::FromStr;

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

/// Why a message's address or arguments couldn't be used. The `Display` text names the address
/// and what was expected, e.g. `/channel/3/volume: argument 0: expected f, got (i)`. The router
/// logs it at WARN and drops the message.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum ArgError {
    /// Argument `index` is missing or has the wrong type. `got` lists the type tags received.
    Arg {
        addr: String,
        index: usize,
        expected: &'static str,
        got: String,
    },
    /// A path segment (a channel or slot id, say) didn't parse.
    Segment {
        addr: String,
        part: String,
        expected: &'static str,
    },
    /// Some other problem with the message as a whole.
    Invalid { addr: String, message: String },
}

impl ArgError {
    /// An error that isn't about one argument or segment.
    pub(super) fn invalid(addr: &str, message: impl Into<String>) -> Self {
        ArgError::Invalid {
            addr: addr.to_string(),
            message: message.into(),
        }
    }
}

impl fmt::Display for ArgError {
    /// `<address>: argument <i>: expected <tag>, got (<tags>)` and the like.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ArgError::Arg {
                addr,
                index,
                expected,
                got,
            } => write!(
                f,
                "{addr}: argument {index}: expected {expected}, got ({got})"
            ),
            ArgError::Segment {
                addr,
                part,
                expected,
            } => write!(f, "{addr}: path segment '{part}': expected {expected}"),
            ArgError::Invalid { addr, message } => write!(f, "{addr}: {message}"),
        }
    }
}

impl std::error::Error for ArgError {}

/// Parse a path segment such as a channel or slot id.
pub(super) fn segment<T: FromStr>(addr: &str, part: &str) -> Result<T, ArgError> {
    part.parse().map_err(|_| ArgError::Segment {
        addr: addr.to_string(),
        part: part.to_string(),
        expected: std::any::type_name::<T>(),
    })
}

/// Reads typed OSC arguments by position; errors name the address and what was expected.
///
/// The plain readers (`int`, `float`, `bool`, `string`, `blob`) accept exactly one OSC type, as
/// the route arms always did. The `lenient_int` and `*_or_int` readers keep the wider acceptance of
/// the arms that had it (Godot sends whole numbers as `i`, `h` or `f` depending on how it built
/// them). The `opt_*` readers return `None` for an argument that is absent or of another type,
/// for arguments with a default.
pub(super) struct Args<'a> {
    addr: &'a str,
    args: &'a [OscType],
}

impl<'a> Args<'a> {
    /// Wrap the arguments of the message sent to `addr`.
    pub(super) fn new(addr: &'a str, args: &'a [OscType]) -> Self {
        Self { addr, args }
    }

    /// The address the message was sent to.
    pub(super) fn addr(&self) -> &'a str {
        self.addr
    }

    /// The error for argument `index` not being what the arm needs (`expected` is an OSC type
    /// tag such as `f`, or a list such as `f or i`).
    pub(super) fn mismatch(&self, index: usize, expected: &'static str) -> ArgError {
        ArgError::Arg {
            addr: self.addr.to_string(),
            index,
            expected,
            got: osc_arg_types(self.args),
        }
    }

    /// Require exactly `count` arguments, for messages whose arm only matched that exact shape.
    pub(super) fn exactly(&self, count: usize) -> Result<(), ArgError> {
        if self.args.len() == count {
            Ok(())
        } else {
            Err(ArgError::invalid(
                self.addr,
                format!(
                    "expected {count} arguments, got {} ({})",
                    self.args.len(),
                    osc_arg_types(self.args)
                ),
            ))
        }
    }

    /// An `i` argument.
    pub(super) fn int(&self, i: usize) -> Result<i32, ArgError> {
        match self.args.get(i) {
            Some(OscType::Int(v)) => Ok(*v),
            _ => Err(self.mismatch(i, "i")),
        }
    }

    /// An `i` argument that is not negative.
    pub(super) fn non_negative(&self, i: usize) -> Result<usize, ArgError> {
        match self.args.get(i) {
            Some(OscType::Int(v)) if *v >= 0 => Ok(*v as usize),
            _ => Err(self.mismatch(i, "i (not negative)")),
        }
    }

    /// An `i` or `h` argument that is not negative.
    pub(super) fn unsigned(&self, i: usize) -> Result<u64, ArgError> {
        match self.args.get(i) {
            Some(OscType::Int(v)) if *v >= 0 => Ok(*v as u64),
            Some(OscType::Long(v)) if *v >= 0 => Ok(*v as u64),
            _ => Err(self.mismatch(i, "i or h (not negative)")),
        }
    }

    /// An `f` argument.
    pub(super) fn float(&self, i: usize) -> Result<f32, ArgError> {
        match self.args.get(i) {
            Some(OscType::Float(v)) => Ok(*v),
            _ => Err(self.mismatch(i, "f")),
        }
    }

    /// An `i` argument read as a flag (any non-zero value is true).
    pub(super) fn bool(&self, i: usize) -> Result<bool, ArgError> {
        self.int(i).map(|v| v != 0)
    }

    /// An `s` argument.
    pub(super) fn string(&self, i: usize) -> Result<&'a str, ArgError> {
        match self.args.get(i) {
            Some(OscType::String(v)) => Ok(v.as_str()),
            _ => Err(self.mismatch(i, "s")),
        }
    }

    /// A `b` argument.
    pub(super) fn blob(&self, i: usize) -> Result<&'a [u8], ArgError> {
        match self.args.get(i) {
            Some(OscType::Blob(v)) => Ok(v.as_slice()),
            _ => Err(self.mismatch(i, "b")),
        }
    }

    /// A whole number sent as `i`, `h` or `f` (see `osc_int`).
    pub(super) fn lenient_int(&self, i: usize) -> Result<i64, ArgError> {
        self.args
            .get(i)
            .and_then(osc_int)
            .ok_or_else(|| self.mismatch(i, "i, h or f"))
    }

    /// A number sent as `f` or `i`.
    pub(super) fn float_or_int(&self, i: usize) -> Result<f32, ArgError> {
        self.opt_float_or_int(i)
            .ok_or_else(|| self.mismatch(i, "f or i"))
    }

    /// An optional `f` argument: `None` when absent or not an `f`.
    pub(super) fn opt_float(&self, i: usize) -> Option<f32> {
        match self.args.get(i) {
            Some(OscType::Float(v)) => Some(*v),
            _ => None,
        }
    }

    /// An optional `f` or `i` argument: `None` when absent or of another type.
    pub(super) fn opt_float_or_int(&self, i: usize) -> Option<f32> {
        match self.args.get(i) {
            Some(OscType::Float(v)) => Some(*v),
            Some(OscType::Int(v)) => Some(*v as f32),
            _ => None,
        }
    }

    /// An optional `i` flag: `None` when absent or not an `i`.
    pub(super) fn opt_bool(&self, i: usize) -> Option<bool> {
        self.int(i).ok().map(|v| v != 0)
    }

    /// An optional `s` argument: `None` when absent or not an `s`.
    pub(super) fn opt_string(&self, i: usize) -> Option<&'a str> {
        self.string(i).ok()
    }
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

#[cfg(test)]
mod tests {
    use super::test_support::string;
    use super::*;

    #[test]
    fn arg_error_names_address_expected_and_received_types() {
        let args = [OscType::Int(3)];
        let err = Args::new("/channel/3/volume", &args).float(0).unwrap_err();
        assert_eq!(
            err.to_string(),
            "/channel/3/volume: argument 0: expected f, got (i)"
        );
        // A missing argument shows an empty list.
        let err = Args::new("/transport/seek", &[]).int(0).unwrap_err();
        assert_eq!(
            err.to_string(),
            "/transport/seek: argument 0: expected i, got ()"
        );
        // The whole list is shown, not just the offending argument.
        let args = [OscType::Int(1), string("x")];
        let err = Args::new("/a", &args).float(1).unwrap_err();
        assert_eq!(err.to_string(), "/a: argument 1: expected f, got (i s)");
    }

    #[test]
    fn segment_parses_ids_and_names_the_bad_part() {
        assert_eq!(segment::<usize>("/channel/12/mute", "12"), Ok(12));
        assert_eq!(segment::<u8>("/m", "255"), Ok(255));
        let err = segment::<usize>("/channel/x/mute", "x").unwrap_err();
        assert_eq!(
            err.to_string(),
            "/channel/x/mute: path segment 'x': expected usize"
        );
        assert!(segment::<u8>("/m", "256").is_err());
        assert!(segment::<usize>("/m", "-1").is_err());
    }

    #[test]
    fn plain_readers_accept_exactly_one_type() {
        let args = [
            OscType::Int(7),
            OscType::Float(0.5),
            string("hi"),
            OscType::Blob(vec![1, 2]),
            OscType::Long(9),
        ];
        let a = Args::new("/x", &args);
        assert_eq!(a.int(0), Ok(7));
        assert_eq!(a.float(1), Ok(0.5));
        assert_eq!(a.string(2), Ok("hi"));
        assert_eq!(a.blob(3), Ok(&[1u8, 2][..]));
        assert_eq!(a.bool(0), Ok(true));
        // Int is not a Float, Float is not an Int, and nothing converts to a string.
        assert!(a.float(0).is_err());
        assert!(a.int(1).is_err());
        assert!(a.int(4).is_err());
        assert!(a.string(0).is_err());
        assert!(a.blob(2).is_err());
        assert!(a.int(9).is_err());
    }

    #[test]
    fn bool_is_an_int_that_is_not_zero() {
        let args = [OscType::Int(0), OscType::Int(-4), OscType::Float(1.0)];
        let a = Args::new("/x", &args);
        assert_eq!(a.bool(0), Ok(false));
        assert_eq!(a.bool(1), Ok(true));
        assert!(a.bool(2).is_err());
        assert_eq!(a.opt_bool(2), None);
        assert_eq!(a.opt_bool(1), Some(true));
    }

    #[test]
    fn lenient_readers_keep_the_older_acceptance() {
        let args = [
            OscType::Int(5),
            OscType::Long(1 << 40),
            OscType::Float(3.9),
            OscType::Double(0.25),
            string("no"),
        ];
        let a = Args::new("/x", &args);
        assert_eq!(a.lenient_int(0), Ok(5));
        assert_eq!(a.lenient_int(1), Ok(1 << 40));
        assert_eq!(a.lenient_int(2), Ok(3));
        assert!(a.lenient_int(3).is_err());
        assert!(a.lenient_int(4).is_err());
        // float_or_int takes f and i only.
        assert_eq!(a.float_or_int(0), Ok(5.0));
        assert_eq!(a.float_or_int(2), Ok(3.9));
        assert!(a.float_or_int(1).is_err());
        assert!(a.float_or_int(3).is_err());
    }

    #[test]
    fn optional_readers_fall_back_instead_of_failing() {
        let args = [OscType::Float(0.5), OscType::Int(2), string("s")];
        let a = Args::new("/x", &args);
        assert_eq!(a.opt_float(0), Some(0.5));
        // An int where a float is optional reads as absent, as pan's second value always did.
        assert_eq!(a.opt_float(1), None);
        assert_eq!(a.opt_float(7), None);
        assert_eq!(a.opt_float_or_int(1), Some(2.0));
        assert_eq!(a.opt_float_or_int(2), None);
        assert_eq!(a.opt_string(2), Some("s"));
        assert_eq!(a.opt_string(0), None);
    }

    #[test]
    fn sign_checked_readers_reject_negatives() {
        let args = [
            OscType::Int(-1),
            OscType::Int(4),
            OscType::Long(5),
            OscType::Long(-5),
        ];
        let a = Args::new("/x", &args);
        assert!(a.non_negative(0).is_err());
        assert_eq!(a.non_negative(1), Ok(4));
        assert!(a.non_negative(2).is_err());
        assert!(a.unsigned(0).is_err());
        assert_eq!(a.unsigned(1), Ok(4));
        assert_eq!(a.unsigned(2), Ok(5));
        assert!(a.unsigned(3).is_err());
    }

    #[test]
    fn exactly_checks_the_argument_count() {
        let args = [OscType::Int(1), OscType::Int(2)];
        let a = Args::new("/transport/loop", &args);
        assert!(a.exactly(2).is_ok());
        let err = a.exactly(3).unwrap_err();
        assert_eq!(
            err.to_string(),
            "/transport/loop: expected 3 arguments, got 2 (i i)"
        );
    }
}
