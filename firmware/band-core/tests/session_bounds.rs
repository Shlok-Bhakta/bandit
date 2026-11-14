//! neural-playground: what a burst from the band costs, and how much a misbehaving stream can hold.

mod common;

use band_core::datax::{DataXReceiver, MAX_FRAME, encode_frame};
use band_core::events::Event;
use band_core::proto::{field_bytes, field_int};
use band_core::session::BandSession;
use common::*;

fn gyro_frame(stamp: u64) -> Vec<u8> {
    let payload = [field_int(1, stamp), field_int(2, stamp), field_bytes(3, &[1, 0, 2, 0, 3, 0])].concat();
    encode_frame(0x8010, &[GYRO], &payload).unwrap()
}

/// One record of a few KB of gyro (the band catching up) comes out one event at a time, the
/// same events `feed` collects.
#[test]
fn a_record_of_motion_streams_its_events() {
    let mut peer = Peer::legacy(true, false);
    let frames: Vec<u8> = (0..150).flat_map(|i| gyro_frame(1_000_000 + i * 10_000)).collect();
    assert!(frames.len() > 3000);
    let record = peer.band.encrypt(&frames).unwrap();
    let mut motions = 0;
    let mut most = 0;
    let mut held = 0;
    peer.session
        .feed_into(&record, 100.0, &mut |event| {
            held += 1;
            most = most.max(held);
            if matches!(event, Event::Motion { .. }) {
                motions += 1;
            }
            held -= 1;
        })
        .unwrap();
    assert_eq!(motions, 150);
    assert_eq!(most, 1);

    let mut other = Peer::legacy(true, false);
    let record = other.band.encrypt(&frames).unwrap();
    let events = other.session.feed(&record, 100.0).unwrap().events;
    assert_eq!(events.iter().filter(|e| matches!(e, Event::Motion { .. })).count(), 150);
}

/// A header claiming more than `MAX_FRAME` ends the session at once instead of holding every
/// later record while it waits.
#[test]
fn a_frame_too_large_to_wait_for_is_an_error() {
    let mut receiver = DataXReceiver::default();
    let mut record = vec![0u8; 16];
    record[..2].copy_from_slice(&((MAX_FRAME as u16) | 0x0001).to_be_bytes());
    assert!(receiver.feed(&record).is_err());
    // Just under the limit waits for the rest.
    let mut receiver = DataXReceiver::default();
    record[..2].copy_from_slice(&((MAX_FRAME - 4) as u16).to_be_bytes());
    assert!(receiver.feed(&record).unwrap().is_empty());
    assert_eq!(receiver.pending_len(), 16);
}

#[test]
fn padding_left_over_is_not_read_as_a_frame_too_large() {
    // 12 bytes of frame and 4 of padding (0xc4): the padding, read as a header, claims ~50 KB.
    let frame = encode_frame(5, &[], &[1, 2, 3, 4, 5, 6, 7, 8]).unwrap();
    let mut receiver = DataXReceiver::default();
    let first = [&frame[..], &[0xc4; 4][..]].concat();
    assert_eq!(receiver.feed(&first).unwrap().len(), 1);
    assert_eq!(receiver.pending_len(), 0);
    // A frame split over two records, the second padded.
    let long = encode_frame(5, &[], &(0..16).collect::<Vec<u8>>()).unwrap();
    assert!(receiver.feed(&long[..16]).unwrap().is_empty());
    let rest = [&long[16..], &[0xcc; 12][..]].concat();
    assert_eq!(receiver.feed(&rest).unwrap().len(), 1);
    assert_eq!(receiver.pending_len(), 0);
    // The residual ambiguity (a split frame read early) leaves padding behind: not an error.
    let split = [&frame[..6], &[0xca; 10][..]].concat();
    assert_eq!(receiver.feed(&split).unwrap().len(), 1);
    assert_eq!(receiver.pending_len(), 4);
}

#[test]
fn recent_records_are_kept_short() {
    let mut receiver = DataXReceiver::default();
    let frames: Vec<u8> = (0..100).flat_map(|i| gyro_frame(i)).collect();
    let padded = [frames.clone(), vec![0xc0 + (16 - frames.len() % 16) as u8; 16 - frames.len() % 16]].concat();
    for _ in 0..6 {
        receiver.feed(&padded).unwrap();
    }
    assert_eq!(receiver.recent().len(), 4);
    assert!(receiver.recent().iter().all(|record| record.len() <= 256));
}

#[test]
fn an_overlong_setup_message_is_an_error() {
    let mut session = BandSession::new(None, None, false);
    let mut bytes = vec![0x8f, 0xff, 0x00, 0x01];
    bytes.extend(vec![0; 64]);
    assert!(session.feed(&bytes, 0.0).is_err());
}

#[test]
fn diagnostics_waiting_to_be_taken_are_capped() {
    let mut peer = Peer::legacy(true, false);
    peer.session.set_log_frames(true);
    let _ = peer.session.take_diagnostics();
    let frames: Vec<u8> = (0..300).flat_map(|i| gyro_frame(1_000_000 + i * 10_000)).collect();
    for chunk in frames.chunks(gyro_frame(0).len() * 100) {
        let record = peer.band.encrypt(chunk).unwrap();
        peer.session.feed(&record, 100.0).unwrap();
    }
    let lines = peer.session.take_diagnostics();
    assert!(lines.len() <= 129, "{}", lines.len());
    assert!(lines.last().unwrap().contains("more lines dropped"));
}
