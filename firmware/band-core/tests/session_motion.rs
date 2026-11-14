mod common;

use band_core::events::Event;
use common::*;

fn motions(events: &[Event]) -> Vec<(u64, [f64; 3])> {
    events.iter().filter_map(|e| match e { Event::Motion { timestamp_us, gyro } => Some((*timestamp_us, *gyro)), _ => None }).collect()
}

#[test]
fn every_gyro_sample_is_reported_with_the_bands_clock() {
    let mut peer = Peer::legacy(true, false);
    let events = peer.gyro3(1_000_000, [100, -200, 300], 0.0).unwrap();
    assert_eq!(motions(&events), [(1_000_000, [100.0, -200.0, 300.0])]);
}

#[test]
fn every_orientation_sample_is_reported() {
    let mut peer = Peer::legacy(true, false);
    peer.gyro3(1_000_000, [0, 0, 0], 0.0).unwrap();
    let q = [0.5f32, 0.5, 0.5, 0.5];
    let events = peer.orientation(1_010_000, q, 0.01).unwrap();
    assert!(events.iter().any(|e| matches!(e, Event::Orientation(v) if *v == q)), "{events:?}");
}
