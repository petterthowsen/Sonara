//! Metronome commands (spec 053). Each only copies a few values into the state's
//! [`Metronome`](crate::audio::metronome::Metronome): the pattern table is fixed-size and the
//! hosts are preallocated, so they are fast under the state lock. The `Vec` a pattern command
//! carries goes to `CommandEffects` to be freed after the lock is released.

use super::CommandEffects;
use crate::audio::metronome::MetronomeSound;
use crate::audio::state::EngineState;
use tracing::warn;

pub(super) fn set_enabled(state: &mut EngineState, enabled: bool) {
    state.metronome.set_enabled(enabled);
}

pub(super) fn set_sound(state: &mut EngineState, sound: MetronomeSound) {
    state.metronome.set_sound(sound);
}

/// Store the pattern of `num/den`; empty `levels` remove it. A malformed one is warned about and
/// ignored (the previous pattern stays).
pub(super) fn set_pattern(
    state: &mut EngineState,
    num: u16,
    den: u16,
    resolution: u8,
    levels: Vec<u8>,
    effects: &mut CommandEffects,
) {
    if let Err(err) = state.metronome.set_pattern(num, den, resolution, &levels) {
        warn!("Metronome pattern {}/{} ignored: {}", num, den, err);
    }
    effects.discard(levels);
}

pub(super) fn clear_patterns(state: &mut EngineState) {
    state.metronome.clear_patterns();
}

pub(super) fn audition(state: &mut EngineState, level: u8) {
    state.metronome.audition(level);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::commands::{process_command, AudioCommand};
    use crate::audio::metronome::{Pattern, SoundKind};

    fn run(state: &mut EngineState, cmd: AudioCommand) -> CommandEffects {
        let mut effects = CommandEffects::default();
        process_command(state, cmd, 64, &mut effects);
        effects
    }

    #[test]
    fn commands_reach_the_metronome() {
        let mut state = EngineState::default();
        assert!(!state.metronome.enabled());
        run(&mut state, AudioCommand::SetMetronomeEnabled(true));
        assert!(state.metronome.enabled());

        let sound = MetronomeSound {
            kind: SoundKind::Wood,
            tune_hz: 99_999.0,
            ..MetronomeSound::default()
        };
        run(&mut state, AudioCommand::SetMetronomeSound(sound));
        assert_eq!(state.metronome.sound().kind, SoundKind::Wood);
        assert_eq!(
            state.metronome.sound().tune_hz,
            4000.0,
            "clamped engine-side"
        );

        let effects = run(
            &mut state,
            AudioCommand::SetMetronomePattern {
                num: 4,
                den: 4,
                resolution: 8,
                levels: vec![4, 0, 1, 0, 2, 0, 3, 0],
            },
        );
        assert_eq!(
            effects.trash.len(),
            1,
            "the levels vec is freed after the lock"
        );
        let p = state.metronome.patterns().resolve(4, 4);
        assert_eq!((p.resolution, p.steps), (8, 8));
        assert_eq!(&p.levels[..8], &[4, 0, 1, 0, 2, 0, 3, 0]);

        // A malformed pattern leaves the stored one alone.
        run(
            &mut state,
            AudioCommand::SetMetronomePattern {
                num: 4,
                den: 4,
                resolution: 8,
                levels: vec![1, 1, 1],
            },
        );
        assert_eq!(state.metronome.patterns().resolve(4, 4).steps, 8);

        // No levels removes it.
        run(
            &mut state,
            AudioCommand::SetMetronomePattern {
                num: 4,
                den: 4,
                resolution: 8,
                levels: vec![],
            },
        );
        assert_eq!(
            state.metronome.patterns().resolve(4, 4),
            Pattern::default_for(4, 4)
        );

        run(
            &mut state,
            AudioCommand::SetMetronomePattern {
                num: 3,
                den: 4,
                resolution: 4,
                levels: vec![4, 1, 1],
            },
        );
        assert_eq!(state.metronome.patterns().len(), 1);
        run(&mut state, AudioCommand::ClearMetronomePatterns);
        assert!(state.metronome.patterns().is_empty());
    }
}
