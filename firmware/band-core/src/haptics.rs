//! Descriptor-backed haptics RPC encoding for Android and Linux clients.

use crate::error::{Result, perr};
use crate::proto::{field_bytes, field_int};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HapticsCommand {
    Vibrate { duration_ms: u64, amplitude: u8 },
    Perform { pattern_id: u32 },
}

impl HapticsCommand {
    pub fn encode_rpc(self, sequence: u32) -> Result<Vec<u8>> {
        if sequence == 0 { return Err(perr("Haptics RPC sequence must be nonzero")); }
        let haptics = match self {
            Self::Vibrate { duration_ms, amplitude } => {
                if duration_ms == 0 { return Err(perr("Vibration duration must be positive")); }
                let vibrate = [field_int(1, duration_ms), field_int(3, u64::from(amplitude))].concat();
                field_bytes(1, &vibrate)
            }
            Self::Perform { pattern_id } => {
                if !matches!(pattern_id, 1 | 2) { return Err(perr("Only verified gesture-feedback patterns 1 and 2 are supported")); }
                field_bytes(2, &field_int(1, u64::from(pattern_id)))
            }
        };
        Ok([field_int(1, u64::from(sequence)), field_bytes(17, &haptics)].concat())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn encodes_vibration_and_feedback_patterns() {
        assert_eq!(HapticsCommand::Vibrate { duration_ms: 100, amplitude: 255 }.encode_rpc(1).unwrap(), [0x08,0x01,0x8a,0x01,0x07,0x0a,0x05,0x08,0x64,0x18,0xff,0x01]);
        assert_eq!(HapticsCommand::Perform { pattern_id: 2 }.encode_rpc(2).unwrap(), [0x08,0x02,0x8a,0x01,0x04,0x12,0x02,0x08,0x02]);
    }
}
