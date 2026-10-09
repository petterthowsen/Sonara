//! `moduleinfo.json` parsing: read a bundle's class list without loading the binary
//! (spec 028 decisions: scanning never loads a plugin into the engine process).
//!
//! The SDK's moduleinfo tool writes relaxed JSON with trailing commas (see any JUCE or
//! DecentSampler bundle), so the input is normalized before `serde_json` sees it.

use serde::Deserialize;

use super::{tuid_from_hex, tuid_to_hex, ScannedClass};

/// The category string VST3 uses for processors (components); controller classes are
/// "Component Controller Class" and are skipped by the scanner.
pub const AUDIO_MODULE_CLASS: &str = "Audio Module Class";

#[derive(Debug, Deserialize)]
struct ModuleInfoFile {
    #[serde(rename = "Classes")]
    classes: Vec<ClassEntry>,
}

#[derive(Debug, Deserialize)]
struct ClassEntry {
    #[serde(rename = "CID")]
    cid: String,
    #[serde(rename = "Category")]
    category: String,
    #[serde(rename = "Name")]
    name: String,
    #[serde(rename = "Vendor", default)]
    vendor: String,
    #[serde(rename = "Version", default)]
    version: String,
    #[serde(rename = "Sub Categories", default)]
    subcategories: SubCategories,
}

#[derive(Debug, Deserialize)]
#[serde(untagged)]
enum SubCategories {
    PipeSeparated(String),
    List(Vec<String>),
}

impl SubCategories {
    fn joined(self) -> String {
        match self {
            Self::PipeSeparated(text) => text,
            Self::List(items) => items.join("|"),
        }
    }
}

impl Default for SubCategories {
    fn default() -> Self {
        Self::PipeSeparated(String::new())
    }
}

/// Remove trailing commas that the moduleinfo tool emits before `}` and `]`, without
/// touching commas inside strings.
pub fn strip_trailing_commas(json: &str) -> String {
    let mut out = String::with_capacity(json.len());
    let mut in_string = false;
    let mut escaped = false;
    let bytes = json.as_bytes();
    for (index, byte) in bytes.iter().enumerate() {
        if in_string {
            out.push(*byte as char);
            if escaped {
                escaped = false;
            } else if *byte == b'\\' {
                escaped = true;
            } else if *byte == b'"' {
                in_string = false;
            }
            continue;
        }
        if *byte == b'"' {
            in_string = true;
            out.push('"');
            continue;
        }
        if *byte == b',' {
            // A comma whose next non-whitespace character closes a block is trailing.
            let next = bytes[index + 1..].iter().find(|b| !b.is_ascii_whitespace());
            if matches!(next, Some(b'}') | Some(b']')) {
                continue;
            }
        }
        out.push(*byte as char);
    }
    out
}

/// Parse `moduleinfo.json` text into the audio-module classes. Classes whose CID is not a
/// valid 32 hex character id and non-audio classes (controllers) are skipped.
pub fn parse(json: &str) -> Result<Vec<ScannedClass>, String> {
    let relaxed = strip_trailing_commas(json);
    let file: ModuleInfoFile =
        serde_json::from_str(&relaxed).map_err(|e| format!("invalid moduleinfo.json: {}", e))?;
    let classes = file
        .classes
        .into_iter()
        .filter(|entry| entry.category == AUDIO_MODULE_CLASS)
        .filter_map(|entry| {
            let id = tuid_from_hex(entry.cid.trim())?;
            Some(ScannedClass {
                id: tuid_to_hex(&id),
                name: entry.name,
                vendor: entry.vendor,
                version: entry.version,
                subcategories: entry.subcategories.joined(),
                category: entry.category,
            })
        })
        .collect();
    Ok(classes)
}

/// Read the class list from `<bundle>/Contents/Resources/moduleinfo.json`, when the bundle
/// has one.
pub fn read_bundle(bundle: &std::path::Path) -> Option<Result<Vec<ScannedClass>, String>> {
    let path = bundle.join("Contents/Resources/moduleinfo.json");
    let json = std::fs::read_to_string(path).ok()?;
    Some(parse(&json))
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = r#"{
      "Name": "DecentSampler",
      "Version": "1.36.1",
      "Factory Info": {
        "Vendor": "Decidedly",
        "URL": "http://decided.ly",
        "E-Mail": "dave@decentsamples.com",
        "Flags": {
          "Unicode": true,
          "Classes Discardable": false,
        },
      },
      "Classes": [
        {
          "CID": "ABCDEF019182FAEB446C647944736D70",
          "Category": "Audio Module Class",
          "Name": "DecentSampler",
          "Vendor": "Decidedly",
          "Version": "1.36.1",
          "Sub Categories": [
            "Instrument",
            "Synth",
          ],
          "Class Flags": 2,
          "Cardinality": 2147483647,
        },
        {
          "CID": "ABCDEF011234ABCD446C647944736D70",
          "Category": "Component Controller Class",
          "Name": "DecentSampler",
          "Sub Categories": [
            "Instrument",
          ],
        },
      ],
    }"#;

    #[test]
    fn parses_classes_with_trailing_commas() {
        let classes = parse(SAMPLE).unwrap();
        assert_eq!(classes.len(), 1, "controller classes are skipped");
        let class = &classes[0];
        assert_eq!(class.id, "ABCDEF019182FAEB446C647944736D70");
        assert_eq!(class.name, "DecentSampler");
        assert_eq!(class.vendor, "Decidedly");
        assert_eq!(class.version, "1.36.1");
        assert_eq!(class.subcategories, "Instrument|Synth");
        assert_eq!(class.category, "Audio Module Class");
    }

    #[test]
    fn accepts_pipe_separated_subcategories() {
        let json = r#"{
          "Classes": [
            {
              "CID": "ABCDEF019182FAEB446C647944736D70",
              "Category": "Audio Module Class",
              "Name": "Effect",
              "Sub Categories": "Fx|Dynamics",
            },
          ],
        }"#;
        let classes = parse(json).unwrap();
        assert_eq!(classes[0].subcategories, "Fx|Dynamics");
        // Missing optional fields default to empty strings.
        assert_eq!(classes[0].vendor, "");
        assert_eq!(classes[0].version, "");
    }

    #[test]
    fn skips_broken_cids_instead_of_failing() {
        let json = r#"{
          "Classes": [
            { "CID": "not-hex", "Category": "Audio Module Class", "Name": "Broken" },
            { "CID": "ABCDEF019182FAEB446C647944736D70", "Category": "Audio Module Class", "Name": "Good" },
          ],
        }"#;
        let classes = parse(json).unwrap();
        assert_eq!(classes.len(), 1);
        assert_eq!(classes[0].name, "Good");
    }

    #[test]
    fn strip_trailing_commas_keeps_string_commas() {
        let json = r#"{"a": "hello, world", "b": [1, 2,],"c": {"d": 3,}}"#;
        assert_eq!(
            strip_trailing_commas(json),
            r#"{"a": "hello, world", "b": [1, 2],"c": {"d": 3}}"#
        );
    }
}
