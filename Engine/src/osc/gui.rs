//! Plugin GUI events and the host windows they drive.

use rosc::OscType;
use tracing::warn;

use super::parse::osc_int;
use super::server::OscServer;
use crate::audio::devices::DevicePath;

/// GUI events from the status thread that need `WindowManager` access on the main loop.
pub(super) enum GuiEvent {
    Opened {
        channel_id: usize,
        device_path: DevicePath,
        width: u32,
        height: u32,
        floating: bool,
    },
    Resize {
        channel_id: usize,
        device_path: DevicePath,
        width: u32,
        height: u32,
    },
    Closed {
        channel_id: usize,
        device_path: DevicePath,
    },
}

impl OscServer {
    /// `{device}/gui/embedded parent_xid`: the host window is now in `parent_xid` (0 = out of
    /// any Godot window). Godot waits for it before hiding or freeing a window the plugin was in:
    /// Godot destroys a native window's X window when it hides it, and every child with it.
    pub(super) fn send_gui_embedded(
        &self,
        channel_id: usize,
        device_path: &DevicePath,
        parent_xid: u64,
    ) {
        let addr = device_path.to_osc_addr(channel_id, "gui/embedded");
        // X11 XIDs are 29 bits, so an Int carries them
        if let Err(e) = self.send_message(&addr, vec![OscType::Int(parent_xid as i32)]) {
            warn!("Failed to send {}: {}", addr, e);
        }
    }
}

/// Parse plugin GUI embed args: `[parent_xid] x y w h [scroll_x scroll_y]` (all ints), with the
/// parent XID only when `with_xid`. The XID is 0 without it. None for a short list, a
/// non-numeric arg or a non-positive XID; width and height are at least 1.
pub(super) fn parse_embed_args(
    args: &[OscType],
    with_xid: bool,
) -> Option<(u64, crate::window_manager::EmbedRect)> {
    let ints = args.iter().map(osc_int).collect::<Option<Vec<i64>>>()?;
    let (xid, rest) = if with_xid {
        let (&xid, rest) = ints.split_first()?;
        if xid <= 0 {
            return None;
        }
        (xid as u64, rest)
    } else {
        (0, &ints[..])
    };
    let [x, y, w, h, ref scroll @ ..] = *rest else {
        return None;
    };
    let rect = crate::window_manager::EmbedRect {
        x: x as i32,
        y: y as i32,
        width: w.max(1) as u32,
        height: h.max(1) as u32,
        scroll_x: scroll.first().copied().unwrap_or(0) as i32,
        scroll_y: scroll.get(1).copied().unwrap_or(0) as i32,
    };
    Some((xid, rect))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::window_manager::EmbedRect;

    fn rect(x: i32, y: i32, width: u32, height: u32, sx: i32, sy: i32) -> EmbedRect {
        EmbedRect {
            x,
            y,
            width,
            height,
            scroll_x: sx,
            scroll_y: sy,
        }
    }

    #[test]
    fn parse_embed_args_with_xid() {
        use rosc::OscType::*;
        let parsed = parse_embed_args(
            &[Int(0x3a00007), Int(10), Int(20), Int(920), Int(345)],
            true,
        );
        assert_eq!(parsed, Some((0x3a00007, rect(10, 20, 920, 345, 0, 0))));
        // Long and float args, plus scroll
        let parsed = parse_embed_args(
            &[
                Long(77),
                Float(1.0),
                Int(2),
                Int(300),
                Long(200),
                Int(40),
                Float(5.0),
            ],
            true,
        );
        assert_eq!(parsed, Some((77, rect(1, 2, 300, 200, 40, 5))));
        // Only scroll_x given
        let parsed = parse_embed_args(&[Int(5), Int(0), Int(0), Int(10), Int(10), Int(3)], true);
        assert_eq!(parsed, Some((5, rect(0, 0, 10, 10, 3, 0))));
    }

    #[test]
    fn parse_embed_args_without_xid() {
        use rosc::OscType::*;
        let parsed = parse_embed_args(&[Int(4), Int(8), Int(0), Int(-3), Int(12), Int(6)], false);
        // Width and height are at least 1
        assert_eq!(parsed, Some((0, rect(4, 8, 1, 1, 12, 6))));
    }

    #[test]
    fn parse_embed_args_rejects_bad_input() {
        use rosc::OscType::*;
        // Short lists
        assert_eq!(parse_embed_args(&[], true), None);
        assert_eq!(
            parse_embed_args(&[Int(1), Int(0), Int(0), Int(10)], true),
            None
        );
        assert_eq!(parse_embed_args(&[Int(0), Int(0), Int(10)], false), None);
        // Non-numeric arg
        assert_eq!(
            parse_embed_args(
                &[Int(1), Int(0), String("x".into()), Int(10), Int(10)],
                true
            ),
            None
        );
        // No parent window
        assert_eq!(
            parse_embed_args(&[Int(0), Int(0), Int(0), Int(10), Int(10)], true),
            None
        );
    }
}
