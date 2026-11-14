mod common;

use band_core::events::Event;
use band_core::identity::EnrollmentIdentity;
use band_core::responder::{Responder, SimMode};
use band_core::session::BandSession;
use common::*;
use p256::ecdsa::SigningKey;
use rand_core::OsRng;

/// Connect an owner to a simulated enrolled band: the events it reported, or the first error.
fn connect(busy: bool) -> Result<Vec<Event>, String> {
    let identity = EnrollmentIdentity::new(SigningKey::random(&mut OsRng), None);
    let mut session = BandSession::new(Some(identity), None, false);
    let mut band = Responder::new(SimMode::Enrolled, SigningKey::random(&mut OsRng));
    band.set_busy(busy);
    let mut to_band = session.request().map_err(|e| e.to_string())?;
    let mut events = Vec::new();
    for _ in 0..64 {
        if to_band.is_empty() {
            break;
        }
        let reply = band.respond(&to_band).map_err(|e| e.to_string())?;
        let fed = session.feed(&reply, 1.0).map_err(|e| e.to_string())?;
        events.extend(fed.events);
        to_band = fed.outgoing;
    }
    Ok(events)
}

#[test]
fn a_band_busy_with_another_device_says_so() {
    let error = connect(true).unwrap_err();
    assert!(error.contains("connected to another device"), "{error}");
}

#[test]
fn a_free_band_connects() {
    let events = connect(false).unwrap();
    assert!(events.iter().any(|event| matches!(event, Event::Connected)), "{events:?}");
}

#[test]
fn a_legacy_band_busy_with_another_device_says_so_too() {
    let mut peer = Peer::legacy(false, false);
    let error = peer
        .exchange(0x8001, LINK, &band_core::proto::field_bytes(2, &[1; 16]), 0.0)
        .unwrap_err()
        .to_string();
    assert!(error.contains("connected to another device"), "{error}");
}
