//! Tracks: the sequencing side of a project (clip instances and automation lanes).

use super::clip::ClipInstance;
use super::types::*;

/// Track that generates audio and routes to a channel
#[derive(Debug, Clone)]
pub struct Track {
    pub id: TrackId,
    pub channel_id: ChannelId,
    pub clip_instances: Vec<ClipInstance>,
    /// Automation lanes driving parameters on the track's linked channel.
    pub automation_lanes: Vec<super::automation::AutomationLane>,
}

impl Track {
    pub fn new(id: TrackId, channel_id: ChannelId) -> Self {
        Self {
            id,
            channel_id,
            clip_instances: Vec::new(),
            automation_lanes: Vec::new(),
        }
    }

    /// Mutable lane with this id, if the track has one.
    pub fn automation_lane_mut(
        &mut self,
        lane_id: &str,
    ) -> Option<&mut super::automation::AutomationLane> {
        self.automation_lanes.iter_mut().find(|l| l.id == lane_id)
    }
}
