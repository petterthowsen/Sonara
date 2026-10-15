//! Engine command-line arguments (spec 046). Parsing is separate from `main` so it can be tested.

use std::path::PathBuf;

/// What the engine was started with.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct CliArgs {
    /// `--log-dir <path>`: where the engine writes its logs.
    pub log_dir: Option<PathBuf>,
    /// `--parent-pid <pid>`: the UI that started the engine. The engine exits when it dies.
    pub parent_pid: Option<i32>,
    /// `--version`: print the version and exit.
    pub print_version: bool,
    /// Arguments that weren't understood, for a warning once logging is up.
    pub unknown: Vec<String>,
}

/// Parse the arguments after the program name. Unknown arguments, and known options with a
/// missing or malformed value, are collected in `unknown` and otherwise ignored.
pub fn parse(args: impl Iterator<Item = String>) -> CliArgs {
    let mut out = CliArgs::default();
    let mut args = args.peekable();
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--version" | "-V" => out.print_version = true,
            "--log-dir" => match args.next() {
                Some(v) if !v.is_empty() => out.log_dir = Some(PathBuf::from(v)),
                _ => out.unknown.push(arg),
            },
            "--parent-pid" => match args.next().and_then(|v| v.parse::<i32>().ok()) {
                Some(pid) if pid > 0 => out.parent_pid = Some(pid),
                _ => out.unknown.push(arg),
            },
            _ => out.unknown.push(arg),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(args: &[&str]) -> CliArgs {
        parse(args.iter().map(|s| s.to_string()))
    }

    #[test]
    fn no_arguments_is_all_default() {
        assert_eq!(p(&[]), CliArgs::default());
    }

    #[test]
    fn parses_log_dir() {
        assert_eq!(
            p(&["--log-dir", "/tmp/x"]).log_dir,
            Some(PathBuf::from("/tmp/x"))
        );
    }

    #[test]
    fn parses_parent_pid() {
        assert_eq!(p(&["--parent-pid", "1234"]).parent_pid, Some(1234));
    }

    #[test]
    fn parses_version() {
        assert!(p(&["--version"]).print_version);
    }

    #[test]
    fn ignores_unknown_arguments() {
        let a = p(&["--bogus", "--log-dir", "/a", "extra"]);
        assert_eq!(a.log_dir, Some(PathBuf::from("/a")));
        assert_eq!(a.unknown, vec!["--bogus".to_string(), "extra".to_string()]);
    }

    #[test]
    fn bad_pid_and_missing_values_are_ignored() {
        let a = p(&["--parent-pid", "abc", "--log-dir"]);
        assert_eq!(a.parent_pid, None);
        assert_eq!(a.log_dir, None);
        assert_eq!(a.unknown.len(), 2);
    }
}
