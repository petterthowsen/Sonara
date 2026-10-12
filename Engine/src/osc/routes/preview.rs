//! Browser sample preview routes: `/preview/*` (spec 037).

use anyhow::Result;
use rosc::OscType;

use super::RouteCtx;
use crate::audio::AudioCommand;
use crate::osc::parse::Args;

/// Handle the preview routes. Returns false for an address this area doesn't know, so the
/// caller can report an unknown address.
pub(super) fn route(parts: &[&str], args: &[OscType], cx: &RouteCtx) -> Result<bool> {
    let a = Args::new(cx.addr, args);
    match parts {
        // s:abs_path f:start_s
        ["preview", "play"] => {
            let (path, start_s) = (a.string(0)?.to_string(), a.float(1)?);
            cx.server.play_preview(path, start_s, cx.commands)?;
        }
        ["preview", "stop"] => cx.server.stop_preview(cx.commands)?,
        // f:pos_s
        ["preview", "seek"] => {
            cx.commands
                .send(AudioCommand::SeekPreview { pos_s: a.float(0)? })?;
        }
        _ => return Ok(false),
    }
    Ok(true)
}
