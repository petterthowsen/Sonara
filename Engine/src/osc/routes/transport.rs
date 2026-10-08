//! Transport routes: `/transport/*`.

use anyhow::Result;
use crossbeam::channel::Sender;
use rosc::OscType;
use tracing::{info, warn};

use crate::audio::AudioCommand;
use crate::osc::server::OscServer;

impl OscServer {
    /// Handle transport routes: `/transport/*`. Returns false for an address this area doesn't
    /// know, so the caller can try the next area or report an unknown address.
    pub(super) fn route_transport(
        &self,
        parts: &[&str],
        args: &[OscType],
        command_tx: &Sender<AudioCommand>,
    ) -> Result<bool> {
        match parts {
            // Transport control
            ["transport", "play"] => {
                info!("Play");
                command_tx.send(AudioCommand::Play)?;
            }
            ["transport", "pause"] => {
                info!("Pause");
                command_tx.send(AudioCommand::Pause)?;
            }
            ["transport", "stop"] => {
                info!("Stop");
                command_tx.send(AudioCommand::Stop)?;
            }
            ["transport", "seek"] => {
                if let Some(OscType::Int(ticks)) = args.first() {
                    info!("Seek to tick {}", ticks);
                    command_tx.send(AudioCommand::Seek(*ticks as i64))?;
                }
            }
            ["transport", "loop"] => {
                if let [OscType::Int(enabled), OscType::Int(start), OscType::Int(end)] = args {
                    info!("Loop enabled={} {}..{}", enabled, start, end);
                    command_tx.send(AudioCommand::SetLoop {
                        enabled: *enabled != 0,
                        start: *start as i64,
                        end: *end as i64,
                    })?;
                }
            }
            ["transport", "tempo"] => {
                if let Some(OscType::Float(tempo)) = args.first() {
                    info!("Set tempo to {}", tempo);
                    command_tx.send(AudioCommand::SetTempo(*tempo))?;
                }
            }
            ["transport", "tempo_map"] => {
                let (points, dropped) = parse_tempo_map_args(args);
                if dropped {
                    warn!("/transport/tempo_map: ignoring malformed trailing argument");
                }
                command_tx.send(AudioCommand::SetTempoMap(points))?;
            }
            ["transport", "time_signature_map"] => {
                let (changes, dropped) = parse_time_signature_map_args(args);
                if dropped {
                    warn!(
                        "/transport/time_signature_map: dropped malformed or out-of-range entries"
                    );
                }
                command_tx.send(AudioCommand::SetTimeSignatureMap(changes))?;
            }
            ["transport", "time_signature"] => {
                if let (Some(OscType::Int(num)), Some(OscType::Int(den))) =
                    (args.get(0), args.get(1))
                {
                    info!("Set time signature to {}/{}", num, den);
                    command_tx.send(AudioCommand::SetTimeSignature(*num, *den))?;
                }
            }
            _ => return Ok(false),
        }
        Ok(true)
    }
}

/// Parse `/transport/tempo_map` args (`i:tick, f:bpm` pairs). The flag is true when a trailing
/// or mistyped value was dropped.
fn parse_tempo_map_args(args: &[OscType]) -> (Vec<(i64, f32)>, bool) {
    let mut points = Vec::with_capacity(args.len() / 2);
    let mut dropped = args.len() % 2 == 1;
    for pair in args.chunks_exact(2) {
        match (&pair[0], &pair[1]) {
            (OscType::Int(tick), OscType::Float(bpm)) => points.push((*tick as i64, *bpm)),
            _ => dropped = true,
        }
    }
    (points, dropped)
}

/// Parse `/transport/time_signature_map` args (`i:bar, i:numerator, i:denominator` triples).
/// Out-of-range triples are dropped, duplicate bars keep the last, bar order is kept. The flag is
/// true when anything was dropped.
fn parse_time_signature_map_args(args: &[OscType]) -> (Vec<(u32, u16, u16)>, bool) {
    let mut changes: Vec<(u32, u16, u16)> = Vec::with_capacity(args.len() / 3);
    let mut dropped = args.len() % 3 != 0;
    for triple in args.chunks_exact(3) {
        let (OscType::Int(bar), OscType::Int(num), OscType::Int(den)) =
            (&triple[0], &triple[1], &triple[2])
        else {
            dropped = true;
            continue;
        };
        let in_range =
            *bar >= 2 && (1..=32).contains(num) && matches!(*den, 1 | 2 | 4 | 8 | 16 | 32);
        if !in_range {
            dropped = true;
            continue;
        }
        let entry = (*bar as u32, *num as u16, *den as u16);
        match changes.iter_mut().find(|c| c.0 == entry.0) {
            Some(existing) => *existing = entry,
            None => changes.push(entry),
        }
    }
    (changes, dropped)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tempo_map_args_parse_pairs() {
        let (points, dropped) = parse_tempo_map_args(&[
            OscType::Int(0),
            OscType::Float(120.0),
            OscType::Int(3840),
            OscType::Float(60.0),
        ]);
        assert_eq!(points, vec![(0, 120.0), (3840, 60.0)]);
        assert!(!dropped);

        let (empty, dropped) = parse_tempo_map_args(&[]);
        assert!(empty.is_empty() && !dropped);

        let (points, dropped) =
            parse_tempo_map_args(&[OscType::Int(0), OscType::Float(90.0), OscType::Int(5)]);
        assert_eq!(points, vec![(0, 90.0)]);
        assert!(dropped);
    }

    #[test]
    fn parse_time_signature_map_args_filters() {
        let ints = |v: &[i32]| v.iter().map(|i| OscType::Int(*i)).collect::<Vec<_>>();
        let (c, dropped) = parse_time_signature_map_args(&ints(&[3, 7, 8, 5, 3, 4]));
        assert_eq!(c, vec![(3, 7, 8), (5, 3, 4)]);
        assert!(!dropped);

        let (c, dropped) =
            parse_time_signature_map_args(&ints(&[1, 3, 4, 4, 0, 4, 4, 4, 3, 6, 33, 4]));
        assert!(c.is_empty() && dropped);

        let (c, _) = parse_time_signature_map_args(&ints(&[3, 7, 8, 3, 5, 4]));
        assert_eq!(c, vec![(3, 5, 4)]);

        let (c, dropped) = parse_time_signature_map_args(&[]);
        assert!(c.is_empty() && !dropped);
    }
}
