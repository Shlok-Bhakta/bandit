//! The band handshake, trust setup and input subscription.
//! It never exports session keys.
//!
//! Any `Err` from `feed` is terminal: drop the session. If a ceremony was
//! running, first persist `enrollment()` (set once the band confirmed
//! ownership) — the band may already have changed owner.

use std::collections::HashMap;

use p256::ecdsa::Signature;
use p256::ecdsa::signature::hazmat::{PrehashSigner, PrehashVerifier};
use p256::elliptic_curve::sec1::ToEncodedPoint;
use p256::{PublicKey, SecretKey, ecdh};
use rand_core::{OsRng, RngCore};
use sha2::{Digest, Sha256};

use crate::airshield::{
    AirShieldCipher, AirShieldKeys, AirShieldReceiver, SCHEME_3, SCHEME_26_GUESSES, Variant,
};
use crate::ceremony::{CeremonyHttpRequest, OwnershipCeremony, failure_message};
use crate::datax::{DataXFrame, DataXReceiver, be16, be32, encode_frame};
use crate::dial::PinchDial;
use crate::error::{BandError, Result, perr};
use crate::events::{BatteryDetail, BatteryStatus, EmgConfig, Event, GestureMessage, Hand};
use crate::haptics::HapticsCommand;
use crate::identity::{EnrollmentIdentity, trust_digest};
use crate::handwriting::{Decoder, PAUSE, SYMBOLS, Written, scores, symbol};
use crate::ota::{OtaItemProgress, OtaJob, OtaPlan, OtaStatus};
use crate::proto::{ProtoFields, field_bytes, field_int};

const STREAM_FIELDS: [u32; 3] = [3, 6, 8];
/// The request id of [`BandSession::request_active`], apart from the counted ones.
const ACTIVE_REQUEST: u64 = 1 << 20;
/// The request id of [`BandSession::set_band_handwriting`]'s state change.
const HANDWRITING_REQUEST: u64 = (1 << 20) + 1;
/// Gyro and orientation: off while a firmware update runs (see [`BandSession::ota_start`]),
/// and while the caller doesn't need them ([`BandSession::set_motion`]).
const MOTION_FIELDS: [u32; 2] = [6, 8];
/// `ConfigReq` fields the band's handwriting turns off (as Meta AI's handwriting check does;
/// standby-related, names unknown): put back as the config read found them afterwards.
const HANDWRITING_OFF_FIELDS: [u32; 2] = [13, 21];
/// The stream probe shows this many messages of each kind, then one in [`PROBE_EVERY`].
const PROBE_SHOWN: usize = 40;
const PROBE_EVERY: usize = 200;
/// The channel as the protocol logic knows it: the direction flag and the low
/// byte. Newer firmware sets extra bits (0x1c00) on channels it answers or
/// opens: 0x9c01 for 0x8001, 0x9c02 for 0x8002.
fn route(channel: u16) -> u16 {
    channel & 0x80ff
}

const STREAM_CHANNEL: u16 = 0x8005;
const CONFIGURATION_CHANNEL: u16 = 0x8006;
const CONFIG_SERVICE_CHANNEL: u16 = 0x8007;
const BATTERY_CHANNEL: u16 = 0x8008;
/// Opens an RPC service on a channel; later requests on that channel carry no words.
const SERVICE_OPEN: [u32; 2] = [0x8100ce56, 0x02000314];
const RPC_RESPONSE: u32 = 0x02000315;
const SERVICE_REJECTED: u32 = 0x0300c001;
const RAW_EMG: u32 = 0x0200020a;
/// The on-band model's output (`RawInferenceSample`): 9 gesture scores, or 100 in handwriting.
const RAW_INFERENCE: u32 = 0x0200020c;
const GESTURE: u32 = 0x0200020d;
const GYRO: u32 = 0x0200020f;
const ORIENTATION: u32 = 0x02000212;
const LINK_SETUP: u32 = 0x02001000;

/// What a band held by another device answers to link setup: no status field at all.
const BAND_BUSY: &str = "The band refused the connection: it is probably connected to another device \
(your phone or the Meta AI app). Disconnect it there and it reconnects here.";

/// A link-setup reply's status: `Ok(true)` when the band accepted (field 1 = 1). A missing
/// status means the band is busy with another device (`BAND_BUSY`); a present non-1 status
/// is `Ok(false)`, for the caller's own error. `integer` reads a missing field as 0, so a
/// present 0 also reads as busy.
fn link_accepted(fields: &ProtoFields) -> Result<bool> {
    match fields.integer(1)? {
        0 => Err(perr(BAND_BUSY)),
        status => Ok(status == 1),
    }
}
/// The firmware's log lines, sent once some stream flag beyond 3/6/8 is on (found by the probe).
const BAND_LOG: u32 = 0x02000316;

const FINGERS: [&str; 5] = ["unknown", "thumb", "index", "middle", "notApplicable"];
const ACTIONS: [&str; 21] = [
    "unknown",
    "press",
    "release",
    "tap",
    "doubletap",
    "click",
    "up",
    "down",
    "left",
    "right",
    "wake",
    "swipeIn",
    "swipeOut",
    "ia",
    "partialPress",
    "partialRelease",
    "partialClick",
    "partialUp",
    "partialDown",
    "partialLeft",
    "partialRight",
];
const DERIVED: [&str; 11] = [
    "unknown",
    "singleTap",
    "doubleTap",
    "buttonHold",
    "buttonRelease",
    "buttonUp",
    "buttonDown",
    "buttonLeft",
    "buttonRight",
    "buttonPress",
    "buttonHoldRelease",
];

fn table_name(table: &[&str], value: u64) -> String {
    usize::try_from(value)
        .ok()
        .and_then(|index| table.get(index))
        .map_or_else(
            || format!("unrecognized:{value}"),
            |name| (*name).to_owned(),
        )
}

/// Swift `allSatisfy { flags.contains($0) && flags.integer($0) == value }`: stops at the first miss.
fn all_set(flags: &ProtoFields, fields: &[u32], value: u64) -> Result<bool> {
    for &field in fields {
        if !(flags.contains(field) && flags.integer(field)? == value) {
            return Ok(false);
        }
    }
    Ok(true)
}

fn random<const N: usize>() -> [u8; N] {
    let mut bytes = [0u8; N];
    OsRng.fill_bytes(&mut bytes);
    bytes
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum SetupStage {
    Link,
    Ceremony,
    Identity,
    DeviceInfo,
    Input,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RawStage {
    Config,
    Query,
    Update,
}

#[derive(Debug, Clone, Copy)]
struct RawRequest {
    enabled: bool,
    stage: RawStage,
    id: u64,
    deadline: f64,
}

#[derive(Debug, Clone, Copy)]
struct HandRequest {
    id: u64,
    hand: Option<Hand>,
    reading: bool,
    deadline: f64,
    /// A probe's config write ([`BandSession::probe_config`]), not the hand.
    probe: bool,
}

/// What one `feed` produced: bytes to write to the band and events to act on.
#[derive(Debug, Default)]
pub struct FeedResult {
    pub outgoing: Vec<u8>,
    pub events: Vec<Event>,
}

pub struct BandSession {
    secret: SecretKey,
    public: Vec<u8>,
    challenge: [u8; 16],
    seed: [u8; 32],
    iv: [u8; 16],
    base: u32,
    peer_key: Option<Vec<u8>>,
    peer_challenge: Option<Vec<u8>>,
    /// The scheme the band's EnableEncryption named (3 on older firmware).
    peer_parameters: u64,
    /// Which of `SCHEME_26_GUESSES` to use if the band offers a newer scheme.
    scheme_guess: usize,
    /// The key rules in use, fixed once the band's RequestEncryption arrives.
    variant: Variant,
    /// The band offered a newer scheme, so `variant` is a guess.
    guessing: bool,
    /// Traffic the session skipped, described for the log.
    diagnostics: Vec<String>,
    /// What the band said about itself while connecting.
    device_info: Option<DeviceInfo>,
    /// Describe every frame once streaming, too (debug logging).
    log_frames: bool,
    /// Extra stream flags to request, to find out what else the band sends (see `set_probe`).
    probe: Vec<u32>,
    /// The last stream flags the band reported while probing, so only a change is logged.
    probe_flags: Option<String>,
    /// Messages of each unknown type seen while probing, to keep the log readable.
    probe_counts: HashMap<u32, usize>,
    peer_seed: Option<Vec<u8>>,
    pending: Vec<u8>,
    transmitter: Option<AirShieldCipher>,
    receiver: Option<AirShieldReceiver>,
    datax: DataXReceiver,
    channel_types: HashMap<u16, u32>,
    dial: PinchDial,
    emitted_engagement: bool,
    dial_pending: f64,
    last_dial: f64,
    last_heartbeat: f64,
    streaming: bool,
    stopping: bool,
    stop_acknowledged: bool,
    authenticated_packets: usize,
    motion_messages: usize,
    streams_enabled: bool,
    battery_channel_opened: bool,
    battery_request_id: u64,
    battery_request: Option<(u64, f64)>,
    battery_unavailable: bool,
    raw_emg: bool,
    raw_requested: bool,
    /// neural-playground: describe every gesture message in full (the dongle's gesture lab).
    describe_gestures: bool,
    config_service_opened: bool,
    raw_request_id: u64,
    raw_request: Option<RawRequest>,
    raw_emg_frames: usize,
    raw_emg_bytes: usize,
    setup_stage: SetupStage,
    enrollment: Option<EnrollmentIdentity>,
    ceremony: Option<OwnershipCeremony>,
    app_trusted: bool,
    band_trusted: bool,
    end_link_sent: bool,
    configuration_id: u64,
    hand_request: Option<HandRequest>,
    haptics_request: Option<(u64, f64, u32)>,
    /// Other configuration writes whose responses are still outstanding.
    configuration_requests: Vec<(u64, f64)>,
    last_clock: f64,
    hand: Option<Hand>,
    /// The id and deadline of an asked update status ([`BandSession::ota_status`]) not yet answered.
    ota_request: Option<(u64, f64)>,
    /// A firmware update in progress ([`BandSession::ota_start`]).
    ota_job: Option<OtaJob>,
    /// The band's last update status, and the last line of the update in progress (or done).
    ota_last: Option<OtaStatus>,
    ota_progress: Option<String>,
    /// The files of the running (or last) update and how far each is.
    ota_items: Vec<OtaItemProgress>,
    /// Gyro and orientation are paused for an update: less traffic from the band while it
    /// acknowledges chunks (with them on, build 64 updates kept losing their place).
    ota_quiet: bool,
    /// neural-playground: gyro and orientation off because the caller doesn't need them (they
    /// stream ~70 messages a second, a large part of the band's radio time).
    motion_off: bool,
    /// neural-playground: the caller turns motion on and off ([`Self::set_motion`]), so a
    /// subscription answer may predate the latest change: only the gesture flag is checked.
    motion_managed: bool,
    /// neural-playground: `HANDWRITING_OFF_FIELDS` as the band's config read reported them
    /// (absent: 0), to restore when handwriting stops. None before the config read.
    standby_config: Option<Vec<(u32, u64)>>,
    /// neural-playground: the last battery answer's detail ([`Self::battery_detail`]).
    battery_detail: Option<BatteryDetail>,
    /// Debug: the band's own handwriting ([`BandSession::set_band_handwriting`]), and what it sent.
    band_handwriting: Option<BandHandwriting>,
}

/// What the band's handwriting mode has sent so far.
#[derive(Default)]
pub struct BandHandwriting {
    pub on: bool,
    pub decoder: Decoder,
    /// Symbols as they came: (index, symbol, margin over the runner-up).
    pub tokens: Vec<(usize, &'static str, f32)>,
    pub samples: usize,
    /// The last sample's `pipeline_type` and score count.
    pub pipeline: u64,
    pub floats: usize,
    /// Symbols not yet taken by [`BandSession::take_written`] (for typing into text fields).
    pending: Vec<Written>,
}

impl BandSession {
    /// `enrollment`: connect as the stored owner. `ceremony`: claim a band in
    /// pairing mode. Neither: the legacy startup (bands in pairing mode only).
    /// `raw_emg`: request raw sEMG right after the gesture subscription.
    pub fn new(
        enrollment: Option<EnrollmentIdentity>,
        ceremony: Option<OwnershipCeremony>,
        raw_emg: bool,
    ) -> Self {
        let secret = SecretKey::random(&mut OsRng);
        let public = secret.public_key().to_encoded_point(false).as_bytes()[1..].to_vec();
        Self {
            secret,
            public,
            challenge: random(),
            seed: random(),
            iv: random(),
            base: u32::from_le_bytes(random()),
            peer_key: None,
            peer_challenge: None,
            peer_parameters: 3,
            scheme_guess: 0,
            variant: SCHEME_3,
            guessing: false,
            diagnostics: Vec::new(),
            device_info: None,
            log_frames: false,
            probe: Vec::new(),
            probe_flags: None,
            probe_counts: HashMap::new(),
            peer_seed: None,
            pending: Vec::new(),
            transmitter: None,
            receiver: None,
            datax: DataXReceiver::default(),
            channel_types: HashMap::new(),
            dial: PinchDial::default(),
            emitted_engagement: false,
            dial_pending: 0.0,
            last_dial: f64::NEG_INFINITY,
            last_heartbeat: f64::NEG_INFINITY,
            streaming: false,
            stopping: false,
            stop_acknowledged: false,
            authenticated_packets: 0,
            motion_messages: 0,
            streams_enabled: false,
            battery_channel_opened: false,
            battery_request_id: 0,
            battery_request: None,
            battery_unavailable: false,
            raw_emg,
            raw_requested: false,
            describe_gestures: false,
            config_service_opened: false,
            raw_request_id: 6,
            raw_request: None,
            raw_emg_frames: 0,
            raw_emg_bytes: 0,
            setup_stage: SetupStage::Link,
            enrollment,
            ceremony,
            app_trusted: false,
            band_trusted: false,
            end_link_sent: false,
            configuration_id: 0,
            hand_request: None,
            haptics_request: None,
            configuration_requests: Vec::new(),
            last_clock: 0.0,
            hand: None,
            ota_request: None,
            ota_job: None,
            ota_last: None,
            ota_progress: None,
            ota_items: Vec::new(),
            ota_quiet: false,
            motion_off: false,
            motion_managed: false,
            standby_config: None,
            battery_detail: None,
            band_handwriting: None,
        }
    }

    pub fn stop_acknowledged(&self) -> bool {
        self.stop_acknowledged
    }
    /// Use guess `index` of `SCHEME_26_GUESSES` if the band offers a newer
    /// encryption scheme (no effect on a scheme-3 band).
    pub fn with_scheme_guess(mut self, index: usize) -> Self {
        self.scheme_guess = index;
        self
    }

    /// neural-playground: subscribe without gyro and orientation; [`Self::set_motion`] turns
    /// them on when needed.
    pub fn without_motion(mut self) -> Self {
        self.motion_off = true;
        self.motion_managed = true;
        self
    }

    /// neural-playground: gyro and orientation on or off (the gesture stream stays on); the
    /// bytes to write, nothing if it's already so or the streams aren't up yet (the
    /// subscription then follows this setting).
    pub fn set_motion(&mut self, on: bool) -> Result<Vec<u8>> {
        self.motion_managed = true;
        if self.motion_off != on {
            return Ok(Vec::new());
        }
        self.motion_off = !on;
        if !self.streams_enabled || self.stopping {
            return Ok(Vec::new());
        }
        self.stream_request(3, Some(true))
    }

    /// neural-playground: temperature, voltage and current from the last battery answer (it
    /// comes with each [`Event::BatteryStatus`]).
    pub fn battery_detail(&self) -> Option<BatteryDetail> {
        self.battery_detail
    }

    /// Whether gyro and orientation are asked for.
    pub fn motion_on(&self) -> bool {
        !self.motion_off
    }

    /// neural-playground: the band reports a held index pinch (its "buttonHold") whose motion
    /// [`Self::set_motion`] only now turns on: the pinch dial arms once gyro flows.
    pub fn arm_dial(&mut self, now: f64) {
        self.dial.arm_held(now);
    }

    /// The guess in use, if the band offered a newer scheme.
    pub fn scheme_guess(&self) -> Option<usize> {
        self.guessing.then_some(self.scheme_guess)
    }

    /// neural-playground: every gesture message's fields, as `LAB fields <finger> <action>
    /// <derived>: …` diagnostics (to find what else the band says, like pressure).
    pub fn set_describe_gestures(&mut self, on: bool) {
        self.describe_gestures = on;
    }

    /// Also describe every frame after setup (channel, type words, size).
    pub fn set_log_frames(&mut self, on: bool) {
        self.log_frames = on;
    }

    /// Describe what was skipped since the last call (relay/control records,
    /// frames nothing handles), for the log. Types and sizes only, no payloads.
    /// Also request these stream flags, and describe what comes back: the flags the band
    /// reports, every gesture message in full, and any message type the session doesn't
    /// know. For finding streams beyond gestures and motion (handwriting?). Set before
    /// connecting; the known flags (2 = raw sEMG, 3, 6, 8) are left out.
    pub fn set_probe(&mut self, fields: Vec<u32>) {
        self.probe = fields
            .into_iter()
            .filter(|field| *field != 0 && *field != 2 && !STREAM_FIELDS.contains(field))
            .collect();
    }

    fn probing(&self) -> bool {
        !self.probe.is_empty()
    }

    /// The first [`PROBE_SHOWN`] messages of a kind, then every [`PROBE_EVERY`]th, with its count.
    fn probe_note(&mut self, kind: u32, line: impl FnOnce() -> String) {
        let count = self.probe_counts.entry(kind).or_default();
        *count += 1;
        let count = *count;
        if count <= PROBE_SHOWN || count.is_multiple_of(PROBE_EVERY) {
            self.diagnostics.push(format!("probe #{count} {}", line()));
        }
    }

    /// What the band said about itself while connecting (none before then).
    pub fn device_info(&self) -> Option<&DeviceInfo> {
        self.device_info.as_ref()
    }

    pub fn take_diagnostics(&mut self) -> Vec<String> {
        if let Some(receiver) = self.receiver.as_mut() {
            self.diagnostics.append(&mut receiver.skipped);
        }
        std::mem::take(&mut self.diagnostics)
    }

    pub fn authenticated_packets(&self) -> usize {
        self.authenticated_packets
    }
    pub fn motion_messages(&self) -> usize {
        self.motion_messages
    }
    pub fn streams_enabled(&self) -> bool {
        self.streams_enabled
    }

    /// Current shared configuration sequence, used to match haptics acknowledgements.
    pub fn configuration_sequence(&self) -> u32 { self.configuration_id as u32 }

    /// Haptics wait for other requests and never run during a firmware update.
    pub fn haptics_ready(&self) -> bool {
        self.setup_stage == SetupStage::Input && self.streams_enabled && !self.stopping
            && self.hand_request.is_none() && self.raw_request.is_none()
            && self.battery_request.is_none() && self.ota_request.is_none()
            && self.ota_job.is_none() && self.haptics_request.is_none()
            && self.configuration_requests.is_empty()
    }

    /// Send one haptics request through the active encrypted configuration channel.
    pub fn send_haptics(&mut self, command: HapticsCommand, time: f64) -> Result<Vec<u8>> {
        if !self.haptics_ready() {
            return Err(BandError::Busy("Wait for the live Band control channel and outstanding requests before haptics.".into()));
        }
        let id = self.configuration_id + 1;
        let payload = command.encode_rpc(id as u32)?;
        let frame = encode_frame(CONFIGURATION_CHANNEL, &[], &payload)?;
        let encrypted = self.encrypt(&frame)?;
        self.configuration_id = id;
        let expected_response = match command { HapticsCommand::Vibrate { .. } => 2, HapticsCommand::Perform { .. } => 3 };
        self.haptics_request = Some((id, time + 5.0, expected_response));
        Ok(encrypted)
    }
    pub fn hand(&self) -> Option<Hand> {
        self.hand
    }
    pub fn raw_emg_frames(&self) -> usize {
        self.raw_emg_frames
    }
    pub fn raw_emg_bytes(&self) -> usize {
        self.raw_emg_bytes
    }
    pub fn ceremony(&self) -> Option<&OwnershipCeremony> {
        self.ceremony.as_ref()
    }
    pub fn enrollment(&self) -> Option<&EnrollmentIdentity> {
        self.enrollment.as_ref()
    }
    /// The identity FinishChangeOwner commits, once `ceremony_pair_completed`
    /// succeeded; `None` before that or without a ceremony.
    pub fn pending_identity(&self) -> Option<EnrollmentIdentity> {
        self.ceremony.as_ref()?.pending_identity()
    }
    /// Whether the band's trust proof is checked: the enrollment knows the band's key.
    pub fn band_verified(&self) -> bool {
        self.enrollment
            .as_ref()
            .is_some_and(|identity| identity.band_public_key.is_some())
    }

    /// The first bytes to write after the L2CAP channel opens: RequestEncryption.
    pub fn request(&self) -> Result<Vec<u8>> {
        encode_frame(
            0x8001,
            &[0x81000005, 0x02000001],
            &[
                field_bytes(1, &self.public),
                field_bytes(2, &self.challenge),
                field_int(3, 0),
                // The schemes we support, as a bitmask: what the phone app offers.
                // (Offering only 3 doesn't change what newer firmware picks.)
                field_int(4, 31),
                field_int(7, 16),
            ]
            .concat(),
        )
    }

    fn encrypt(&mut self, frame: &[u8]) -> Result<Vec<u8>> {
        match self.transmitter.as_mut() {
            Some(transmitter) => transmitter.encrypt(frame),
            None => Err(perr("Band encryption is not ready")),
        }
    }

    fn end_link_setup(&self) -> Result<Vec<u8>> {
        encode_frame(
            0x8001,
            &[LINK_SETUP],
            &[field_int(1, 1), field_bytes(2, &random::<16>())].concat(),
        )
    }

    fn device_info_request(&self) -> Result<Vec<u8>> {
        encode_frame(
            0x8003,
            &SERVICE_OPEN,
            &[field_int(1, 1), field_bytes(3, &[])].concat(),
        )
    }

    /// Feed bytes read from the band's L2CAP channel at monotonic `time` (seconds).
    ///
    /// Any `Err` from `feed` is terminal: drop the session. If a ceremony was
    /// running, first persist `enrollment()` (set once the band confirmed
    /// ownership) — the band may already have changed owner.
    pub fn feed(&mut self, bytes: &[u8], time: f64) -> Result<FeedResult> {
        self.last_clock = time;
        self.pending.extend_from_slice(bytes);
        let mut outgoing = Vec::new();
        let mut events = Vec::new();
        while self.receiver.is_none() && self.pending.len() >= 4 {
            if self.pending[0] & 0x80 == 0 {
                return Err(perr("Unexpected bytes before band encryption"));
            }
            let size = usize::from(be16(&self.pending, 0) & 0x7fff) + 4;
            if size < 8 {
                return Err(perr("Invalid band setup length"));
            }
            if self.pending.len() < size {
                break;
            }
            let frame: Vec<u8> = self.pending.drain(..size).collect();
            let offset = if frame[2] & 0x80 != 0 { 8 } else { 4 };
            if size < offset + 4 {
                return Err(perr("Truncated band setup header"));
            }
            let kind = be32(&frame, offset);
            let fields = ProtoFields::parse(&frame[offset + 4..])?;
            let point = fields.bytes_len(1, 64)?.to_vec();
            let peer = PublicKey::from_sec1_bytes(&[&[4u8][..], &point].concat())
                .map_err(|_| perr("Invalid band public key"))?;
            match kind {
                0x02000001 => {
                    let curve = fields.integer(3)?;
                    let parameters = fields.integer(4)?;
                    // `parameters` is a bitmask of the band's supported schemes. Older
                    // firmware offers exactly 3; newer offers 27 and then uses 26,
                    // whose key rules are guessed (bits 3 and 4 are 31's).
                    let newer = parameters & 24 != 0;
                    if self.peer_key.is_some() || curve != 0 || !(newer || parameters & 3 == 3) {
                        return Err(perr(format!(
                            "Unsupported band encryption parameters (repeated request: {}, curve {curve}, parameters {parameters}, field 7: {})",
                            self.peer_key.is_some(),
                            fields
                                .integer(7)
                                .map_or_else(|_| "?".to_string(), |v| v.to_string())
                        )));
                    }
                    self.peer_challenge = Some(fields.bytes_len(2, 16)?.to_vec());
                    self.peer_key = Some(point);
                    self.guessing = newer;
                    self.variant = if newer {
                        SCHEME_26_GUESSES[self.scheme_guess % SCHEME_26_GUESSES.len()]
                    } else {
                        SCHEME_3
                    };
                    outgoing.extend(encode_frame(
                        1,
                        &[0x02000002],
                        &[
                            field_bytes(1, &self.public),
                            field_bytes(2, &self.seed),
                            field_bytes(3, &self.iv),
                            field_int(4, u64::from(self.base)),
                            field_int(5, self.variant.announce),
                        ]
                        .concat(),
                    )?);
                }
                0x02000002 => {
                    let parameters = fields.integer(5)?;
                    let peer_challenge = match (&self.peer_key, &self.peer_challenge) {
                        // Newer firmware names 26 here whatever we offered; whether
                        // `variant` is right shows in the first packet either way.
                        (Some(key), Some(challenge)) if *key == point => challenge.clone(),
                        _ => {
                            return Err(perr(format!(
                                "Unexpected band encryption response (same key: {}, parameters {parameters})",
                                self.peer_key.as_deref() == Some(point.as_slice())
                            )));
                        }
                    };
                    self.peer_parameters = parameters;
                    let shared =
                        ecdh::diffie_hellman(self.secret.to_nonzero_scalar(), peer.as_affine());
                    let secret = shared.raw_secret_bytes().as_slice();
                    let peer_seed = fields.bytes_len(2, 32)?.to_vec();
                    let peer_iv: [u8; 16] =
                        fields.bytes_len(3, 16)?.try_into().expect("length checked");
                    let peer_counter = u32::try_from(fields.integer(4)?)
                        .map_err(|_| perr("Invalid band packet counter"))?;
                    self.transmitter = Some(AirShieldCipher::new(
                        AirShieldKeys::derive_variant(
                            self.variant,
                            secret,
                            &peer_challenge,
                            &self.seed,
                        )?,
                        self.iv,
                        self.base,
                    ));
                    self.receiver = Some(AirShieldReceiver::new(AirShieldCipher::new(
                        AirShieldKeys::derive_variant(
                            self.variant,
                            secret,
                            &self.challenge,
                            &peer_seed,
                        )?,
                        peer_iv,
                        peer_counter,
                    )));
                    self.peer_seed = Some(peer_seed);
                    if self.ceremony.is_some() {
                        // Enrollment runs the ownership ceremony instead of the identity
                        // queries; it rejoins the enrolled flow at trust.
                        self.setup_stage = SetupStage::Ceremony;
                        let start = self.ceremony.as_ref().expect("checked").start()?;
                        outgoing.extend(self.encrypt(&start)?);
                    } else if self.enrollment.is_some() {
                        // Enrolled startup replaces the empty identity query with an
                        // EnableTrust proof. Link setup waits for mutual trust.
                        self.setup_stage = SetupStage::Identity;
                        let proof = self.enable_trust(false)?;
                        outgoing.extend(self.encrypt(&proof)?);
                    } else {
                        // Complete link setup before opening the input service.
                        let query = encode_frame(0x8002, &[0x81000024, 0x02003000], &[])?;
                        outgoing.extend(self.encrypt(&query)?);
                        let end = self.end_link_setup()?;
                        outgoing.extend(self.encrypt(&end)?);
                    }
                }
                _ => return Err(perr("Unrecognized band setup message")),
            }
        }
        if self.receiver.is_some() {
            let records = self
                .receiver
                .as_mut()
                .expect("checked")
                .feed(&self.pending)
                .map_err(|error| {
                    if self.authenticated_packets == 0 && self.guessing {
                        perr(format!(
                            "{error} (the band chose encryption scheme {}; key guess {} was wrong)",
                            self.peer_parameters, self.scheme_guess
                        ))
                    } else {
                        error
                    }
                })?;
            self.pending.clear();
            // neural-playground: a burst (the caller fell behind) mustn't keep its buffer: on the
            // dongle that's heap the next burst can't get.
            if self.pending.capacity() > 4096 {
                self.pending.shrink_to(512);
            }
            if self.receiver.as_ref().is_some_and(|receiver| receiver.cipher.pads_aligned()) {
                self.datax.set_always_padded();
            }
            for plaintext in records {
                self.authenticated_packets += 1;
                let frames = self.datax.feed(&plaintext)?;
                if matches!(
                    self.setup_stage,
                    SetupStage::Ceremony | SetupStage::Identity | SetupStage::Link
                ) {
                    // Setup only: header bytes (length, channel, type words), no payload.
                    let head = &plaintext[..plaintext.len().min(12)];
                    self.diagnostics.push(format!(
                        "packet {}: {} plaintext bytes, starts {:02x?}; frames {:?}; {} bytes held for a later packet",
                        self.authenticated_packets,
                        plaintext.len(),
                        head,
                        frames
                            .iter()
                            .map(|frame| format!(
                                "ch {:#x} words {:08x?} {}B",
                                frame.channel,
                                frame.words,
                                frame.payload.len()
                            ))
                            .collect::<Vec<_>>(),
                        self.datax.pending_len()
                    ));
                }
                for frame in frames {
                    if self.log_frames && self.setup_stage == SetupStage::Input {
                        self.diagnostics.push(format!(
                            "frame ch {:#x} words {:08x?} {}B",
                            frame.channel,
                            frame.words,
                            frame.payload.len()
                        ));
                    }
                    let produced = match self.input(&frame, time, &mut outgoing) {
                        // A frame whose protobuf doesn't parse (seen mid-update on build 64) is
                        // dropped, not the connection: the record carrying it was authenticated.
                        Err(BandError::Protocol(message))
                            if self.setup_stage == SetupStage::Input && message.contains("protobuf") =>
                        {
                            let head: String = frame.payload.iter().take(24).map(|b| format!("{b:02x}")).collect();
                            self.diagnostics.push(format!(
                                "skipped a frame ({message}): ch {:#x} words {:08x?} {}B {head}",
                                frame.channel,
                                frame.words,
                                frame.payload.len()
                            ));
                            // The records just before, to see how the reading lost its place.
                            for (age, record) in self.datax.recent().iter().enumerate() {
                                let hex: String = record.iter().map(|b| format!("{b:02x}")).collect();
                                self.diagnostics.push(format!("skipped: record -{age} ({}B) {hex}", record.len()));
                            }
                            Vec::new()
                        }
                        other => other?,
                    };
                    events.extend(produced);
                }
                if self.streaming && !self.stopping && time - self.last_heartbeat >= 0.2 {
                    self.last_heartbeat = time;
                    events.push(Event::Heartbeat);
                }
            }
        }
        Ok(FeedResult { outgoing, events })
    }

    /// Call periodically (e.g. every 50 ms): expires requests and releases the dial.
    pub fn tick(&mut self, time: f64) -> Vec<Event> {
        self.last_clock = time;
        self.configuration_requests.retain(|(_, deadline)| time < *deadline);
        self.dial.tick(time);
        let mut events = self.engagement_events();
        if !self.stopping
            && self
                .hand_request
                .is_some_and(|request| time >= request.deadline)
        {
            self.hand_request = None;
            self.hand = None;
            events.push(Event::HandednessFailure(
                "Couldn't confirm the band hand. Reconnect and try again.".into(),
            ));
        }
        if !self.stopping
            && self
                .battery_request
                .is_some_and(|(_, deadline)| time >= deadline)
        {
            self.battery_request = None;
            events.push(Event::BatteryStatus(None));
        }
        if !self.stopping
            && self
                .raw_request
                .is_some_and(|request| time >= request.deadline)
        {
            self.raw_request = None;
            events.push(Event::RawEmgFailure(
                "The band didn't confirm the EMG change. Turn readings off, then try again.".into(),
            ));
        }
        if !self.stopping && self.ota_request.is_some_and(|(_, deadline)| time >= deadline) {
            self.ota_request = None;
            self.diagnostics.push("ota: the band didn't answer the update status request".into());
        }
        if !self.stopping && self.haptics_request.is_some_and(|(_, deadline, _)| time >= deadline) {
            let (id, _, _) = self.haptics_request.take().expect("checked pending haptics");
            events.push(Event::HapticsFinished { sequence: id as u32, rpc_success: false, haptics_success: None });
        }
        events
    }

    /// Update the existing input subscription. Gesture and motion flags stay on.
    pub fn set_raw_emg_enabled(&mut self, enabled: bool, time: f64) -> Result<Vec<u8>> {
        if self.stopping {
            return Err(BandError::Busy(
                "Wait for the band to reconnect before changing readings.".into(),
            ));
        }
        if self.raw_request.is_some() {
            return Err(BandError::Busy(
                "Wait for the current EMG change to finish.".into(),
            ));
        }
        self.raw_emg = enabled;
        if !self.streams_enabled {
            return Ok(Vec::new());
        }
        self.raw_request_id += 1;
        let id = self.raw_request_id;
        self.raw_request = Some(RawRequest {
            enabled,
            stage: if enabled {
                RawStage::Config
            } else {
                RawStage::Update
            },
            id,
            deadline: time + 8.0,
        });
        if enabled {
            let words: &[u32] = if self.config_service_opened {
                &[]
            } else {
                &SERVICE_OPEN
            };
            self.config_service_opened = true;
            let frame = encode_frame(
                CONFIG_SERVICE_CHANNEL,
                words,
                &[field_int(1, id), field_bytes(5, &[])].concat(),
            )?;
            return self.encrypt(&frame);
        }
        self.raw_stream_update(id, false)
    }

    fn raw_stream_update(&mut self, id: u64, enabled: bool) -> Result<Vec<u8>> {
        self.raw_requested = true;
        let control: Vec<u8> = std::iter::once(field_int(2, u64::from(enabled)))
            .chain(STREAM_FIELDS.iter().map(|&field| field_int(field, 1)))
            .chain(self.probe.iter().map(|&field| field_int(field, 1)))
            .flatten()
            .collect();
        let frame = encode_frame(
            STREAM_CHANNEL,
            &[],
            &[field_int(1, id), field_bytes(4, &control)].concat(),
        )?;
        self.encrypt(&frame)
    }

    /// Write the band's hand setting, then confirm it with an independent read.
    pub fn set_handedness(&mut self, hand: Hand, time: f64) -> Result<Vec<u8>> {
        if !self.streams_enabled
            || self.stopping
            || self.hand.is_none()
            || self.hand_request.is_some()
        {
            return Err(BandError::Busy(
                "Wait for the band to report its hand before changing it.".into(),
            ));
        }
        self.dial = PinchDial::default();
        self.request_hand(Some(hand), false, time)
    }

    /// Put the band in its active state (`ConfigReq.deviceState` = ACTIVE), as Meta AI's gesture
    /// screens do. The band can come up in standby, notably after a firmware update (seen after
    /// installing build 70): it then runs its wake model (`ia_od_…`), whose only gesture, "IA",
    /// it drops before sending (`index_ia_enabled=no`), so the app sees nothing at all. We can't
    /// watch for IA for that reason; asking for active on every connection covers it instead.
    /// The answer isn't needed.
    /// Sent right after the hand read (which opens the service), under its own request id
    /// so the hand requests keep theirs.
    fn request_active(&mut self) -> Result<Vec<u8>> {
        let frame = encode_frame(
            CONFIGURATION_CHANNEL,
            &[],
            &[field_int(1, ACTIVE_REQUEST), field_bytes(5, &field_int(6, 2))].concat(),
        )?;
        let bytes = self.encrypt(&frame)?;
        self.configuration_requests.push((ACTIVE_REQUEST, self.last_clock + 5.0));
        Ok(bytes)
    }

    /// Write an arbitrary `ConfigReq` and return the bytes to send.
    ///
    /// The band persists several settings in `Config` — `deviceState`,
    /// `emgSensorState`, `mode`, `dataCollectionModeEnabled` — so anything that
    /// changes them must change them back. This is the escape hatch for that;
    /// `stop()` only disables the streams, it does not restore the config.
    pub fn write_config(&mut self, config: &[u8]) -> Result<Vec<u8>> {
        if self.stopping {
            return Err(BandError::Busy("The session is stopping.".into()));
        }
        let id = self.configuration_id + 1;
        let words: &[u32] = if self.configuration_id == 0 {
            &SERVICE_OPEN
        } else {
            &[]
        };
        let frame = encode_frame(
            CONFIGURATION_CHANNEL,
            words,
            &[field_int(1, id), field_bytes(5, config)].concat(),
        )?;
        let bytes = self.encrypt(&frame)?;
        self.configuration_id = id;
        self.configuration_requests.push((id, self.last_clock + 5.0));
        Ok(bytes)
    }

    fn request_hand(&mut self, hand: Option<Hand>, reading: bool, time: f64) -> Result<Vec<u8>> {
        let id = self.configuration_id + 1;
        // ConfigReq.is_left_handed is field 10. An empty ConfigReq reads current settings.
        let config = if reading {
            Vec::new()
        } else {
            field_int(10, u64::from(hand == Some(Hand::Left)))
        };
        let words: &[u32] = if self.configuration_id == 0 {
            &SERVICE_OPEN
        } else {
            &[]
        };
        let frame = encode_frame(
            CONFIGURATION_CHANNEL,
            words,
            &[field_int(1, id), field_bytes(5, &config)].concat(),
        )?;
        let bytes = self.encrypt(&frame)?;
        self.configuration_id = id;
        self.hand_request = Some(HandRequest {
            id,
            hand,
            reading,
            deadline: time + 5.0,
            probe: false,
        });
        Ok(bytes)
    }

    /// Probe only: write `body` as a ConfigReq (the fields of the config read, e.g. 46 =
    /// `{3=1}`), log the band's answer, then read the whole config back into the log.
    pub fn probe_config(&mut self, body: &[u8], time: f64) -> Result<Vec<u8>> {
        if !self.streams_enabled || self.stopping || self.hand_request.is_some() {
            return Err(BandError::Busy("Wait for the band to finish connecting.".into()));
        }
        ProtoFields::parse(body)?;
        let id = self.configuration_id + 1;
        let words: &[u32] = if self.configuration_id == 0 { &SERVICE_OPEN } else { &[] };
        let frame = encode_frame(
            CONFIGURATION_CHANNEL,
            words,
            &[field_int(1, id), field_bytes(5, body)].concat(),
        )?;
        let bytes = self.encrypt(&frame)?;
        self.configuration_id = id;
        self.diagnostics.push(format!("probe: writing config {}", ProtoFields::parse(body)?.describe_nested(0)));
        self.hand_request = Some(HandRequest {
            id,
            hand: None,
            reading: false,
            deadline: time + 5.0,
            probe: true,
        });
        Ok(bytes)
    }

    /// Debug: ask the band's update service for its status, read only: an empty
    /// `OtaReq.deviceInfoRequest` (field 7 of the RPC request, beside ConfigReq's 5, on the
    /// same service). The answer (`OtaResp.deviceInfoResponse`: protocol version, state,
    /// firmware and model versions, key version) goes to the log.
    pub fn ota_status(&mut self) -> Result<Vec<u8>> {
        if !self.streams_enabled || self.stopping || self.hand_request.is_some() || self.ota_request.is_some() {
            return Err(BandError::Busy("Wait for the band to finish connecting.".into()));
        }
        let id = self.configuration_id + 1;
        let words: &[u32] = if self.configuration_id == 0 { &SERVICE_OPEN } else { &[] };
        let ota = field_bytes(1, &[]);
        let frame = encode_frame(
            CONFIGURATION_CHANNEL,
            words,
            &[field_int(1, id), field_bytes(7, &ota)].concat(),
        )?;
        let bytes = self.encrypt(&frame)?;
        self.configuration_id = id;
        self.ota_request = Some((id, self.last_clock + 5.0));
        self.diagnostics.push(format!("ota: asking the band's update status (request {id})"));
        Ok(bytes)
    }

    /// The band's last reported update status (see [`ota_status`](Self::ota_status)).
    pub fn ota_last_status(&self) -> Option<OtaStatus> {
        self.ota_last
    }

    /// The latest line of the running (or last) update, and whether one is running.
    pub fn ota_progress(&self) -> (Option<&str>, bool) {
        (self.ota_progress.as_deref(), self.ota_job.is_some())
    }

    /// Whether a Cancel is safe now: no update running, or one that hasn't sent Commit.
    pub fn ota_cancellable(&self) -> bool {
        self.ota_job.as_ref().is_none_or(OtaJob::cancellable)
    }

    /// The files of the running (or last) update and how far each is.
    pub fn ota_items(&self) -> &[OtaItemProgress] {
        &self.ota_items
    }

    fn ota_log(&mut self, lines: Vec<String>) {
        if let Some(last) = lines.last() {
            self.ota_progress = Some(last.trim_start_matches("ota: ").to_owned());
        }
        self.diagnostics.extend(lines);
    }

    /// Debug: run a firmware update (see [`crate::ota`]): a trial that ends with Abort, or an
    /// install that ends with Commit. Progress goes to the log; returns the first bytes to write.
    pub fn ota_start(&mut self, plan: OtaPlan, time: f64) -> Result<Vec<u8>> {
        if self.haptics_request.is_some() {
            return Err(BandError::Busy("Wait for the haptics response before starting an update.".into()));
        }
        if !self.streams_enabled || self.stopping || self.hand_request.is_some() || self.ota_request.is_some() {
            return Err(BandError::Busy("Wait for the band to finish connecting.".into()));
        }
        // Cancel stops a running update (before its Commit), then aborts what the band holds.
        if let Some(job) = &self.ota_job {
            if plan.mode != crate::ota::OtaMode::Cancel || job.mode() == crate::ota::OtaMode::Cancel {
                return Err(BandError::Busy("An update is already running.".into()));
            }
            if !job.cancellable() {
                return Err(BandError::Busy("The band is installing: it isn't safe to cancel now.".into()));
            }
            self.ota_job = None;
            self.diagnostics.push("ota: stopping the update".into());
        }
        let mut job = OtaJob::new(plan);
        let mut ids = self.configuration_id;
        let bodies = job.begin(&mut ids, time);
        let mut bytes = self.ota_frames(bodies, ids)?;
        bytes.extend(self.set_ota_quiet(true)?);
        let lines = job.log();
        self.ota_log(lines);
        self.ota_items = job.items();
        self.ota_job = Some(job);
        Ok(bytes)
    }

    /// Debug: resend late update chunks and give up on silent requests; bytes to write.
    pub fn ota_tick(&mut self, time: f64) -> Result<Vec<u8>> {
        let Some(mut job) = self.ota_job.take() else { return Ok(Vec::new()) };
        if self.stopping {
            return Ok(Vec::new());
        }
        let mut ids = self.configuration_id;
        let bodies = job.tick(&mut ids, time);
        let lines = job.log();
        self.ota_log(lines);
        self.ota_items = job.items();
        let mut bytes = self.ota_frames(bodies, ids)?;
        if job.done() {
            bytes.extend(self.set_ota_quiet(false)?);
        } else {
            self.ota_job = Some(job);
        }
        Ok(bytes)
    }

    /// Debug: the band's own handwriting on or off. On: `deviceState` HANDWRITING_CC (4), with
    /// standby off (as Meta AI's handwriting check sets it), and the RawInference stream; off:
    /// back to ACTIVE (2), without it. What it sends is decoded as it comes ([`Self::band_handwriting`]).
    pub fn set_band_handwriting(&mut self, on: bool) -> Result<Vec<u8>> {
        if !self.streams_enabled || self.stopping || self.ota_job.is_some() {
            return Err(BandError::Busy("Wait for the band to finish connecting.".into()));
        }
        let config = handwriting_config(on, self.standby_config.as_deref());
        let frame = encode_frame(
            CONFIGURATION_CHANNEL,
            &[],
            &[field_int(1, HANDWRITING_REQUEST), field_bytes(5, &config)].concat(),
        )?;
        let mut bytes = self.encrypt(&frame)?;
        self.configuration_requests.push((HANDWRITING_REQUEST, self.last_clock + 5.0));
        let handwriting = self.band_handwriting.get_or_insert_with(BandHandwriting::default);
        if on && !handwriting.on {
            *handwriting = BandHandwriting::default();
        }
        handwriting.on = on;
        bytes.extend(self.stream_request(3, Some(true))?);
        Ok(bytes)
    }

    /// Debug: what the band's handwriting mode has sent (None before it was turned on).
    pub fn band_handwriting(&self) -> Option<&BandHandwriting> {
        self.band_handwriting.as_ref()
    }

    /// The symbols the band wrote since the last call, oldest first.
    pub fn take_written(&mut self) -> Vec<Written> {
        self.band_handwriting.as_mut().map(|h| std::mem::take(&mut h.pending)).unwrap_or_default()
    }

    /// Whether the band is in its handwriting state (as asked).
    pub fn band_writing(&self) -> bool {
        self.band_handwriting.as_ref().is_some_and(|h| h.on)
    }

    /// Debug: forget what the band's handwriting sent so far.
    pub fn clear_band_handwriting(&mut self) {
        if let Some(handwriting) = &mut self.band_handwriting {
            let on = handwriting.on;
            *handwriting = BandHandwriting { on, ..BandHandwriting::default() };
        }
    }

    /// Pause (or resume) gyro and orientation for an update; the bytes to write.
    fn set_ota_quiet(&mut self, quiet: bool) -> Result<Vec<u8>> {
        if self.ota_quiet == quiet {
            return Ok(Vec::new());
        }
        self.ota_quiet = quiet;
        self.stream_request(3, Some(true))
    }

    /// Frame and encrypt update requests on the configuration service; `ids` is the counter after them.
    fn ota_frames(&mut self, bodies: Vec<Vec<u8>>, ids: u64) -> Result<Vec<u8>> {
        let mut out = Vec::new();
        for body in bodies {
            let words: &[u32] = if self.configuration_id == 0 { &SERVICE_OPEN } else { &[] };
            let frame = encode_frame(CONFIGURATION_CHANNEL, words, &body)?;
            out.extend(self.encrypt(&frame)?);
            self.configuration_id = self.configuration_id.max(1);
        }
        self.configuration_id = self.configuration_id.max(ids);
        Ok(out)
    }

    fn receive_hand(
        &mut self,
        fields: &ProtoFields,
        time: f64,
        outgoing: &mut Vec<u8>,
    ) -> Result<Vec<Event>> {
        let Some(request) = self.hand_request else {
            return Ok(Vec::new());
        };
        if fields.integer(1)? != request.id {
            return Ok(Vec::new());
        }
        self.hand_request = None;
        if request.probe {
            self.diagnostics.push(format!("probe: config write answer: {}", fields.describe_nested(0)));
            outgoing.extend(self.request_hand(None, true, time)?);
            return Ok(Vec::new());
        }
        if self.probing() && request.reading {
            // Every setting the band reports, to find ones beyond the hand (a model choice?).
            self.diagnostics.push(format!("probe: band config: {}", fields.describe_nested(0)));
        }
        let failure = |message: &str| vec![Event::HandednessFailure(message.to_owned())];
        if time >= request.deadline {
            self.hand = None;
            return Ok(failure(
                "Couldn't confirm the band hand. Reconnect and try again.",
            ));
        }
        if fields.integer(2)? != 1 {
            self.hand = None;
            return Ok(failure(
                "The band couldn't apply its hand setting. Reconnect and try again.",
            ));
        }
        if !request.reading {
            // Read it again independently; a successful write status alone isn't confirmation.
            let read = self.request_hand(request.hand, true, time)?;
            outgoing.extend(read);
            return Ok(Vec::new());
        }
        if !fields.contains(6) {
            self.hand = None;
            return Ok(failure("This band didn't report its hand setting."));
        }
        let config = ProtoFields::parse(fields.bytes(6)?)?;
        // The first config read goes out with the stream subscription, before handwriting can be
        // asked for, so it holds the band's own values.
        if self.standby_config.is_none() {
            let saved = HANDWRITING_OFF_FIELDS.iter()
                .map(|&field| Ok((field, if config.contains(field) { config.integer(field)? } else { 0 })))
                .collect::<Result<Vec<_>>>()?;
            self.standby_config = Some(saved);
        }
        if !config.contains(10) || config.integer(10)? > 1 {
            self.hand = None;
            return Ok(failure("This band didn't report its hand setting."));
        }
        let reported = if config.integer(10)? == 1 {
            Hand::Left
        } else {
            Hand::Right
        };
        self.hand = Some(reported);
        let mut events = vec![Event::Handedness(reported)];
        if request.hand.is_some_and(|expected| expected != reported) {
            events.push(Event::HandednessFailure(
                "The band didn't keep the selected hand. Reconnect and try again.".into(),
            ));
        }
        Ok(events)
    }

    /// BatteryInfoReq: an empty read request, separate from sensor subscriptions.
    pub fn query_battery_status(&mut self, time: f64) -> Result<Vec<u8>> {
        if !self.streams_enabled
            || self.stopping
            || self.battery_unavailable
            || self.battery_request.is_some()
        {
            return Ok(Vec::new());
        }
        self.battery_request_id += 1;
        let id = self.battery_request_id;
        self.battery_request = Some((id, time + 3.0));
        let words: &[u32] = if self.battery_channel_opened {
            &[]
        } else {
            &SERVICE_OPEN
        };
        self.battery_channel_opened = true;
        let frame = encode_frame(
            BATTERY_CHANNEL,
            words,
            &[field_int(1, id), field_bytes(2, &[])].concat(),
        )?;
        self.encrypt(&frame)
    }

    /// Read the existing subscription's status when sensor traffic goes quiet.
    pub fn query_stream_state(&mut self) -> Result<Vec<u8>> {
        if !self.streams_enabled || self.stopping || self.raw_request.is_some() {
            return Ok(Vec::new());
        }
        self.stream_request(5, None)
    }

    /// Disable the streams (including raw sEMG if it was requested).
    ///
    /// An empty return means there is nothing to acknowledge — close the channel
    /// now. Otherwise write the bytes and wait up to 3 s for `stop_acknowledged()`.
    pub fn stop(&mut self) -> Result<Vec<u8>> {
        if self.stopping {
            return Ok(Vec::new());
        }
        self.stopping = true;
        self.hand_request = None;
        self.raw_request = None;
        self.battery_request = None;
        if self.transmitter.is_none() || self.setup_stage != SetupStage::Input {
            return Ok(Vec::new());
        }
        self.stream_request(4, Some(false))
    }

    /// Resume the ceremony after the `pair_request` HTTP exchange.
    pub fn ceremony_pair_request_completed(
        &mut self,
        signature: &[u8],
        receipt: &str,
    ) -> Result<Vec<u8>> {
        if self.stopping {
            return Ok(Vec::new());
        }
        let frame = self
            .ceremony
            .as_mut()
            .ok_or_else(|| perr("No enrollment is running"))?
            .pair_request_completed(signature, receipt)?;
        self.encrypt(&frame)
    }

    /// Resume the ceremony after the `pair` HTTP exchange.
    ///
    /// Persist `pending_identity()` as tentative BEFORE writing these bytes; the
    /// band may commit ownership even if its confirmation never arrives. Promote
    /// it on `Event::CeremonyCompleted`.
    pub fn ceremony_pair_completed(
        &mut self,
        signature: &[u8],
        receipt: &str,
        device_public_key: Option<&[u8]>,
    ) -> Result<Vec<u8>> {
        if self.stopping {
            return Ok(Vec::new());
        }
        let frame = self
            .ceremony
            .as_mut()
            .ok_or_else(|| perr("No enrollment is running"))?
            .pair_completed(signature, receipt, device_public_key)?;
        self.encrypt(&frame)
    }

    /// Host EnableTrust on the identity service channel. The service-open word
    /// is only needed before the first identity exchange on the channel.
    fn enable_trust(&self, service_open: bool) -> Result<Vec<u8>> {
        let identity = self
            .enrollment
            .as_ref()
            .ok_or_else(|| perr("No owner identity is stored"))?;
        let (Some(peer_key), Some(peer_challenge)) = (&self.peer_key, &self.peer_challenge) else {
            return Err(perr("Band encryption is not ready"));
        };
        let digest = trust_digest(peer_challenge, peer_key, &self.seed, &self.public);
        let signature: Signature = identity
            .private_key
            .sign_prehash(&digest)
            .map_err(|_| perr("Could not sign the band trust proof"))?;
        let words: &[u32] = if service_open {
            &[0x02001000]
        } else {
            &[0x81000024, 0x02001000]
        };
        encode_frame(
            0x8002,
            words,
            &[
                field_bytes(1, &Sha256::digest(identity.app_point())),
                field_bytes(2, &signature.to_bytes()),
            ]
            .concat(),
        )
    }

    /// Drive one ownership ceremony response. HTTP steps pause the wire flow and
    /// surface `Event::CeremonyHttp`; the caller resumes with the server's reply.
    fn receive_ceremony(
        &mut self,
        frame: &DataXFrame,
        outgoing: &mut Vec<u8>,
    ) -> Result<Vec<Event>> {
        let Some(&kind) = frame.words.last() else {
            return Ok(Vec::new());
        };
        if kind & 0xff00_0000 == 0x0300_0000 {
            let code = kind & 0x00ff_ffff;
            return Err(BandError::OwnershipRejected {
                code,
                message: failure_message(code),
            });
        }
        let ceremony = self
            .ceremony
            .as_mut()
            .expect("ceremony stage implies a ceremony");
        match kind {
            0x02003001 => {
                let next = ceremony.identity_read(&frame.payload)?;
                outgoing.extend(self.encrypt(&next)?);
                Ok(vec![Event::CeremonyStage(
                    "reading the band identity".into(),
                )])
            }
            0x02002001 => {
                let request = ceremony.skip_challenge(&frame.payload)?;
                Ok(vec![
                    Event::CeremonyStage("claiming the band".into()),
                    Event::CeremonyHttp(CeremonyHttpRequest::PairRequest(request)),
                ])
            }
            0x02002003 => {
                let pair = ceremony.start_change_owner(&frame.payload)?;
                Ok(vec![
                    Event::CeremonyStage("confirming ownership".into()),
                    Event::CeremonyHttp(CeremonyHttpRequest::Pair(pair)),
                ])
            }
            0x02002005 => {
                let identity = ceremony.complete(&frame.words, &frame.payload)?;
                // Swap the new identity in and open the enrolled trust flow on the
                // same channel; the identity service is already open there.
                self.enrollment = Some(identity.clone());
                self.app_trusted = false;
                self.band_trusted = false;
                self.end_link_sent = false;
                self.setup_stage = SetupStage::Identity;
                let proof = self.enable_trust(true)?;
                outgoing.extend(self.encrypt(&proof)?);
                Ok(vec![
                    Event::CeremonyCompleted(identity),
                    Event::CeremonyStage("establishing trust".into()),
                ])
            }
            _ => {
                self.diagnostics.push(format!(
                    "unhandled ceremony frame: channel {:#x}, words {:08x?}, {} payload bytes",
                    frame.channel,
                    frame.words,
                    frame.payload.len()
                ));
                Ok(Vec::new())
            }
        }
    }

    /// Handle the enrolled identity exchange until both directions trust each
    /// other, then rejoin the shared EndLinkSetup flow.
    fn receive_identity(
        &mut self,
        frame: &DataXFrame,
        outgoing: &mut Vec<u8>,
    ) -> Result<Vec<Event>> {
        let Some(&kind) = frame.words.last() else {
            return Ok(Vec::new());
        };
        if kind & 0xff00_0000 == 0x0300_0000 && route(frame.channel) == 2 {
            if kind != 0x03001000 {
                let code = kind & 0x00ff_ffff;
                if code == 0x1043 {
                    return Err(BandError::IdentityMismatch {
                        code,
                        message: "band enrolled to a different key. forget the stored band identity to reconnect without it.".into(),
                    });
                }
                return Err(BandError::IdentityMismatch {
                    code,
                    message: format!(
                        "the band rejected the stored identity ({kind:x}). try reconnecting."
                    ),
                });
            }
            self.app_trusted = true;
        } else if kind == 0x02001001 && route(frame.channel) & 0x8000 != 0 {
            if self.band_trusted {
                return Err(perr("The band sent a duplicate identity proof"));
            }
            let fields = ProtoFields::parse(&frame.payload)?;
            let (Some(peer_key), Some(peer_seed)) = (&self.peer_key, &self.peer_seed) else {
                return Err(perr("Band encryption is not ready"));
            };
            let signature = fields.bytes_len(2, 64)?;
            if let Some(band_key) = self
                .enrollment
                .as_ref()
                .and_then(|identity| identity.band_public_key.as_ref())
            {
                let digest = trust_digest(&self.challenge, &self.public, peer_seed, peer_key);
                let valid = Signature::from_slice(signature)
                    .is_ok_and(|proof| band_key.verify_prehash(&digest, &proof).is_ok());
                if !valid {
                    return Err(perr(
                        "The band's identity proof didn't verify. Try reconnecting.",
                    ));
                }
            }
            self.band_trusted = true;
            let ack = encode_frame(frame.channel & 0x7fff, &[0x03001000], &[])?;
            outgoing.extend(self.encrypt(&ack)?);
        } else if kind == LINK_SETUP && route(frame.channel) == 0x8001 && self.end_link_sent {
            let fields = ProtoFields::parse(&frame.payload)?;
            if !link_accepted(&fields)? || fields.bytes(2)?.len() != 16 {
                return Err(perr("Unexpected band link setup response"));
            }
            self.setup_stage = SetupStage::DeviceInfo;
            let info = self.device_info_request()?;
            outgoing.extend(self.encrypt(&info)?);
            return Ok(Vec::new());
        } else {
            return Ok(Vec::new());
        }
        if self.app_trusted && self.band_trusted && !self.end_link_sent {
            self.end_link_sent = true;
            let end = self.end_link_setup()?;
            outgoing.extend(self.encrypt(&end)?);
        }
        Ok(Vec::new())
    }

    fn stream_request(&mut self, id: u64, enabled: Option<bool>) -> Result<Vec<u8>> {
        let mut selected = STREAM_FIELDS.to_vec();
        if enabled == Some(false) && self.raw_requested {
            selected.insert(0, 2);
        }
        selected.extend(&self.probe);
        let quiet = self.ota_quiet || self.motion_off;
        let inference = self.band_handwriting.as_ref().map(|h| h.on);
        let control: Vec<u8> = match enabled {
            Some(on) => selected
                .iter()
                .flat_map(|&field| field_int(field, u64::from(on && !(quiet && MOTION_FIELDS.contains(&field)))))
                // The model's raw output (field 4), only while the band writes.
                // neural-playground: with 22 and 23, which the model output needs (kinesis, rokid-lumen).
                .chain(inference.map_or_else(Vec::new, |write| {
                    [4, 22, 23].iter().flat_map(|&field| field_int(field, u64::from(on && write))).collect()
                }))
                .collect(),
            None => Vec::new(),
        };
        let words: &[u32] = if id == 2 { &SERVICE_OPEN } else { &[] };
        let frame = encode_frame(
            STREAM_CHANNEL,
            words,
            &[field_int(1, id), field_bytes(4, &control)].concat(),
        )?;
        self.encrypt(&frame)
    }

    fn engagement_events(&mut self) -> Vec<Event> {
        if self.dial.engaged() == self.emitted_engagement {
            return Vec::new();
        }
        self.emitted_engagement = self.dial.engaged();
        self.dial_pending = 0.0;
        self.last_dial = f64::NEG_INFINITY;
        vec![Event::DialState(self.emitted_engagement)]
    }

    fn input(
        &mut self,
        frame: &DataXFrame,
        time: f64,
        outgoing: &mut Vec<u8>,
    ) -> Result<Vec<Event>> {
        if let Some(&kind) = frame.words.last() {
            if self.channel_types.len() >= 1024 && !self.channel_types.contains_key(&frame.channel)
            {
                return Err(perr("Too many band input channels"));
            }
            self.channel_types.insert(frame.channel, kind);
        }
        let Some(&kind) = self.channel_types.get(&frame.channel) else {
            return Ok(Vec::new());
        };
        // neural-playground: updated firmware (1054928927) sends its log lines and error words on
        // the channels it answers on, and names a channel's kind only when it changes, so an answer
        // can follow one of those unnamed. An unnamed frame shaped like an answer (request id and
        // status, fields 1 and 2) is one; a log line (field 3 only) isn't.
        let kind = if frame.words.is_empty()
            && (kind == BAND_LOG || kind & 0xff00_0000 == 0x0300_0000)
            && ProtoFields::parse(&frame.payload).is_ok_and(|fields| fields.contains(1) && fields.contains(2))
        {
            RPC_RESPONSE
        } else {
            kind
        };
        if self.ceremony.is_some() && self.setup_stage == SetupStage::Ceremony && !self.stopping {
            return self.receive_ceremony(frame, outgoing);
        }
        if self.enrollment.is_some() && self.setup_stage == SetupStage::Identity && !self.stopping {
            return self.receive_identity(frame, outgoing);
        }
        if kind == LINK_SETUP
            && route(frame.channel) == 0x8001
            && self.setup_stage == SetupStage::Link
            && !self.stopping
        {
            let fields = ProtoFields::parse(&frame.payload)?;
            if !link_accepted(&fields)? {
                return Err(perr(
                    "The band couldn't finish setting up the connection. Try reconnecting.",
                ));
            }
            self.setup_stage = SetupStage::DeviceInfo;
            let info = self.device_info_request()?;
            outgoing.extend(self.encrypt(&info)?);
            return Ok(Vec::new());
        }
        if route(frame.channel) & 0x7fff == BATTERY_CHANNEL & 0x7fff && !self.stopping {
            if kind == SERVICE_REJECTED {
                self.battery_request = None;
                self.battery_unavailable = true;
                return Ok(vec![Event::BatteryStatus(None)]);
            }
            if kind == RPC_RESPONSE
                && let Some((id, _)) = self.battery_request
            {
                // Optional status errors must not interrupt gestures or EMG.
                let matches = ProtoFields::parse(&frame.payload)
                    .ok()
                    .and_then(|fields| fields.required_integer(1).ok())
                    == Some(id);
                if !matches {
                    return Ok(Vec::new());
                }
                self.battery_request = None;
                // neural-playground: the band's temperature, voltage and current, for power measurements.
                self.battery_detail = BatteryDetail::from_response(&frame.payload).ok();
                return Ok(vec![Event::BatteryStatus(
                    BatteryStatus::from_response(&frame.payload).ok(),
                )]);
            }
            return Ok(Vec::new());
        }
        if kind == SERVICE_REJECTED && !self.stopping {
            if route(frame.channel) == 3 && self.setup_stage == SetupStage::DeviceInfo {
                return Err(perr("The band rejected gesture setup. Try reconnecting."));
            }
            if let Some(raw) = self.raw_request
                && (route(frame.channel) == 7
                    || (route(frame.channel) == 5 && raw.stage != RawStage::Config))
            {
                self.raw_request = None;
                return Ok(vec![Event::RawEmgFailure(
                    "The band rejected the EMG request.".into(),
                )]);
            }
            if route(frame.channel) == 5 && self.setup_stage == SetupStage::Input {
                return Err(perr(
                    "The band rejected the input subscription. Try reconnecting.",
                ));
            }
            if route(frame.channel) == 6 && self.ota_request.take().is_some() {
                self.diagnostics.push("ota: the band rejected the update status request".into());
                return Ok(Vec::new());
            }
            if route(frame.channel) == 6 && self.hand_request.is_some() {
                self.hand_request = None;
                self.hand = None;
                return Ok(vec![Event::HandednessFailure(
                    "The band couldn't report its hand setting. Reconnect and try again.".into(),
                )]);
            }
            return Ok(Vec::new());
        }
        // Ignore unrelated services without trying to interpret their protobuf schema.
        if kind == RAW_INFERENCE
            && let Some(handwriting) = &mut self.band_handwriting
            && handwriting.on
        {
            if let Ok(sample) = ProtoFields::parse(&frame.payload) {
                let floats = sample.bytes(3).map(scores).unwrap_or_default();
                handwriting.samples += 1;
                handwriting.pipeline = sample.integer(10).unwrap_or(0);
                handwriting.floats = floats.len();
                if floats.len().is_multiple_of(SYMBOLS) {
                    for chunk in floats.chunks(SYMBOLS) {
                        if let Some((index, margin)) = handwriting.decoder.push(chunk) {
                            let shown = if index == PAUSE { "pause" } else { symbol(index) };
                            handwriting.tokens.push((index, shown, margin));
                            if handwriting.tokens.len() > 500 {
                                handwriting.tokens.drain(..100);
                            }
                        }
                    }
                    handwriting.pending.append(&mut handwriting.decoder.finished);
                }
            }
            return Ok(Vec::new());
        }
        if ![RPC_RESPONSE, RAW_EMG, GESTURE, GYRO, ORIENTATION].contains(&kind) {
            if self.probing() && self.setup_stage == SetupStage::Input {
                // The firmware's own log lines (`[time] <inf> module: text`): every one, as text.
                if kind == BAND_LOG
                    && let Some(text) = ProtoFields::parse(&frame.payload)
                        .ok()
                        .and_then(|fields| ProtoFields::parse(fields.bytes(3).ok()?).ok())
                        .and_then(|line| String::from_utf8(line.bytes(1).ok()?.to_vec()).ok())
                {
                    self.diagnostics.push(format!("band log: {}", text.trim_end()));
                    return Ok(Vec::new());
                }
                let shown = ProtoFields::parse(&frame.payload)
                    .map_or_else(|_| "not protobuf".to_owned(), |fields| fields.describe());
                let channel = frame.channel;
                let size = frame.payload.len();
                self.probe_note(kind, || format!("unknown kind {kind:08x} ch {channel:#x} {size}B: {shown}"));
            }
            return Ok(Vec::new());
        }
        if kind == RPC_RESPONSE
            && route(frame.channel) == 3
            && self.setup_stage == SetupStage::DeviceInfo
            && !self.stopping
        {
            let fields = ProtoFields::parse(&frame.payload)?;
            self.device_info = DeviceInfo::find(&fields, 0).or(self.device_info.take());
            if self.probing() {
                // DeviceInfoResp: firmware, model ids, protocol version, features (handwriting).
                self.diagnostics.push(format!("probe: device info: {}", fields.describe_nested(0)));
            }
            if fields.required_integer(1)? != 1 {
                return Ok(Vec::new());
            }
            if fields.required_integer(2)? != 1 {
                return Err(perr("The band rejected gesture setup. Try reconnecting."));
            }
            self.setup_stage = SetupStage::Input;
            let open = self.stream_request(2, None)?;
            let enable = self.stream_request(3, Some(true))?;
            let hand = self.request_hand(None, true, time)?;
            let active = self.request_active()?;
            outgoing.extend(open);
            outgoing.extend(enable);
            outgoing.extend(hand);
            outgoing.extend(active);
            return Ok(Vec::new());
        }
        if self.setup_stage != SetupStage::Input {
            return Ok(Vec::new());
        }
        if kind == RPC_RESPONSE && route(frame.channel) & 0x7fff == CONFIGURATION_CHANNEL & 0x7fff {
            if self.stopping {
                return Ok(Vec::new());
            }
            let fields = ProtoFields::parse(&frame.payload)?;
            if let Ok(id) = fields.integer(1)
                && let Some(at) = self.configuration_requests.iter().position(|(pending, _)| *pending == id)
            {
                self.configuration_requests.remove(at);
            }
            if let Some((id, _, expected)) = self.haptics_request
                && fields.integer(1).ok() == Some(id)
            {
                self.haptics_request = None;
                let rpc_success = fields.integer(2).ok() == Some(1);
                let haptics_success = fields.bytes(18).ok()
                    .and_then(|bytes| ProtoFields::parse(bytes).ok())
                    .filter(|response| response.bytes(expected).is_ok())
                    .and_then(|response| response.contains(1).then(|| response.integer(1).ok().is_some_and(|code| code == 0)));
                return Ok(vec![Event::HapticsFinished { sequence: id as u32, rpc_success, haptics_success }]);
            }
            if let Some(mut job) = self.ota_job.take() {
                let seq = fields.integer(1).unwrap_or(0);
                if job.owns(seq) {
                    let mut ids = self.configuration_id;
                    let bodies = job.receive(&fields, &mut ids, time);
                    // What the job learned (a key just installed) is the band's status now.
                    if let Some(status) = job.last_status() {
                        self.ota_last = Some(status);
                    }
                    let lines = job.log();
                    self.ota_log(lines);
                    self.ota_items = job.items();
                    outgoing.extend(self.ota_frames(bodies, ids)?);
                    if job.done() {
                        outgoing.extend(self.set_ota_quiet(false)?);
                    } else {
                        self.ota_job = Some(job);
                    }
                    return Ok(Vec::new());
                }
                self.ota_job = Some(job);
            }
            if self.ota_request.is_some_and(|(id, _)| fields.integer(1).ok() == Some(id)) {
                self.ota_request = None;
                self.ota_last = OtaStatus::from_response(&fields);
                match self.ota_last {
                    Some(status) => self.diagnostics.push(format!("ota: update status: {status}")),
                    None => self.diagnostics.push(format!("ota: update status: {}", fields.describe_nested(0))),
                }
                return Ok(Vec::new());
            }
            return self.receive_hand(&fields, time, outgoing);
        }
        if kind == RPC_RESPONSE
            && !self.stopping
            && let Some(pending) = self.raw_request
            && let Some(events) = self.receive_raw(frame, pending, outgoing)?
        {
            return Ok(events);
        }
        if kind == RPC_RESPONSE && route(frame.channel) != STREAM_CHANNEL & 0x7fff {
            return Ok(Vec::new());
        }
        if kind == RPC_RESPONSE {
            let fields = ProtoFields::parse(&frame.payload)?;
            let request = fields.integer(1)?;
            if request == 3 || request == 5 {
                if self.stopping {
                    return Ok(Vec::new());
                }
                if fields.integer(2)? != 1 {
                    if self.probing() {
                        // The extra flags may be what it rejects: subscribe again without them.
                        self.diagnostics.push(format!(
                            "probe: the band rejected the subscription with flags {:?} ({}); retrying without",
                            self.probe,
                            fields.describe()
                        ));
                        self.probe.clear();
                        outgoing.extend(self.stream_request(3, Some(true))?);
                        return Ok(Vec::new());
                    }
                    return Err(perr("The band rejected the input subscription"));
                }
                let flags = ProtoFields::parse(fields.bytes(5)?)?;
                if self.probing() {
                    let shown = flags.describe();
                    if self.probe_flags.as_deref() != Some(shown.as_str()) {
                        self.diagnostics.push(format!("probe: stream flags (request {request}): {shown}"));
                        self.probe_flags = Some(shown);
                    }
                }
                let wanted: &[u32] = if self.ota_quiet || self.motion_managed { &STREAM_FIELDS[..1] } else { &STREAM_FIELDS };
                self.streams_enabled = all_set(&flags, wanted, 1)?;
                if !self.streams_enabled {
                    return Err(perr("The band input subscription stopped"));
                }
                if request == 3 && self.raw_emg && self.raw_request.is_none() {
                    let raw = self.set_raw_emg_enabled(true, time)?;
                    outgoing.extend(raw);
                }
                if !self.streaming {
                    self.streaming = true;
                    return Ok(vec![Event::Connected]);
                }
            } else if request == 4 && fields.integer(2)? == 1 && fields.contains(5) {
                let flags = ProtoFields::parse(fields.bytes(5)?)?;
                let mut expected = STREAM_FIELDS.to_vec();
                if self.raw_requested {
                    expected.insert(0, 2);
                }
                self.stop_acknowledged = all_set(&flags, &expected, 0)?;
            }
            return Ok(Vec::new());
        }
        if self.stopping {
            return Ok(Vec::new());
        }
        if kind == RAW_EMG {
            // Keep the original payload for recordings, including unknown encodings.
            self.raw_emg_frames += 1;
            self.raw_emg_bytes += frame.payload.len();
            let mut events = Vec::new();
            if !self.streaming {
                self.streaming = true;
                events.push(Event::Connected);
                events.push(Event::Heartbeat);
                self.last_heartbeat = time;
            }
            events.push(Event::RawEmgFrame(frame.payload.clone()));
            events.push(Event::DataSeen);
            return Ok(events);
        }
        let fields = ProtoFields::parse(&frame.payload)?;
        let sequence = fields.required_integer(1)?;
        let timestamp = fields.required_integer(2)?;
        let mut events = Vec::new();
        if kind == GESTURE {
            let gesture = GestureMessage {
                sequence,
                timestamp_us: timestamp,
                finger: table_name(&FINGERS, fields.integer(3)?),
                action: table_name(&ACTIONS, fields.integer(4)?),
                derived_action: table_name(&DERIVED, fields.integer(5)?),
                synthetic: fields.integer(12)? != 0,
                received_at: time,
            };
            if self.describe_gestures {
                self.diagnostics.push(format!("LAB fields {} {} {}: {}", gesture.finger, gesture.action, gesture.derived_action, fields.describe()));
            }
            if self.probing() {
                let shown = fields.describe();
                let name = format!("{} {} {}", gesture.finger, gesture.action, gesture.derived_action);
                // Every one: they're few, and the ones during handwriting are the point.
                self.diagnostics.push(format!("probe gesture {name}: {shown}"));
            }
            self.dial.gesture(&gesture, time);
            events.push(Event::Gesture(gesture));
            events.extend(self.engagement_events());
        } else {
            let bytes = fields
                .bytes_len(3, if kind == GYRO { 6 } else { 16 })?
                .to_vec();
            self.motion_messages += 1;
            if !self.streaming {
                self.streaming = true;
                events.push(Event::Connected);
                events.push(Event::Heartbeat);
                self.last_heartbeat = time;
            }
            if kind == GYRO {
                let values: [f64; 3] = std::array::from_fn(|i| {
                    f64::from(i16::from_le_bytes([bytes[i * 2], bytes[i * 2 + 1]]))
                });
                events.push(Event::Motion { timestamp_us: timestamp, gyro: values });
                let delta = self.dial.gyro(timestamp, values, time);
                events.extend(self.engagement_events());
                if let Some(delta) = delta {
                    self.dial_pending += delta;
                    if time - self.last_dial >= 0.02 {
                        events.push(Event::DialTurn(self.dial_pending));
                        self.last_dial = time;
                        self.dial_pending = 0.0;
                    }
                }
            } else {
                let values: [f32; 4] = std::array::from_fn(|i| {
                    f32::from_le_bytes([
                        bytes[i * 4],
                        bytes[i * 4 + 1],
                        bytes[i * 4 + 2],
                        bytes[i * 4 + 3],
                    ])
                });
                let norm: f32 = values.iter().map(|v| v * v).sum();
                if !values.iter().all(|v| v.is_finite()) || !(0.9..=1.1).contains(&norm) {
                    return Err(perr("Invalid band orientation sample"));
                }
                events.push(Event::Orientation(values));
            }
        }
        events.push(Event::DataSeen);
        Ok(events)
    }

    /// The staged raw-sEMG change: config read (0x8007) → status query → update.
    /// Returns `None` when the frame isn't the pending reply.
    fn receive_raw(
        &mut self,
        frame: &DataXFrame,
        pending: RawRequest,
        outgoing: &mut Vec<u8>,
    ) -> Result<Option<Vec<Event>>> {
        let fields = ProtoFields::parse(&frame.payload)?;
        let expected = if pending.stage == RawStage::Config {
            CONFIG_SERVICE_CHANNEL
        } else {
            STREAM_CHANNEL
        };
        if route(frame.channel) & 0x7fff != expected & 0x7fff || fields.integer(1)? != pending.id {
            return Ok(None);
        }
        if fields.integer(2)? != 1 {
            self.raw_request = None;
            return Ok(Some(vec![Event::RawEmgFailure(
                "The band rejected the EMG change. Gestures remain requested.".into(),
            )]));
        }
        match pending.stage {
            RawStage::Config => {
                let Ok(config) = EmgConfig::from_response(&frame.payload) else {
                    self.raw_request = None;
                    return Ok(Some(vec![Event::RawEmgFailure(
                        "The band didn't provide a readable EMG configuration.".into(),
                    )]));
                };
                self.raw_request_id += 1;
                let id = self.raw_request_id;
                self.raw_request = Some(RawRequest {
                    stage: RawStage::Query,
                    id,
                    ..pending
                });
                let query = self.stream_request(id, None)?;
                outgoing.extend(query);
                Ok(Some(vec![Event::RawEmgConfiguration(config)]))
            }
            RawStage::Query => {
                self.raw_request_id += 1;
                let id = self.raw_request_id;
                self.raw_request = Some(RawRequest {
                    stage: RawStage::Update,
                    id,
                    ..pending
                });
                let update = self.raw_stream_update(id, pending.enabled)?;
                outgoing.extend(update);
                Ok(Some(Vec::new()))
            }
            RawStage::Update => {
                self.raw_request = None;
                let flags = ProtoFields::parse(fields.bytes(5)?)?;
                for field in STREAM_FIELDS {
                    if flags.integer(field)? != 1 {
                        return Err(perr(
                            "The band stopped gesture streams during the EMG change. Reconnect with readings off.",
                        ));
                    }
                }
                if flags.integer(2)? != u64::from(pending.enabled) {
                    return Ok(Some(vec![Event::RawEmgFailure(
                        "The band didn't accept EMG alongside gestures.".into(),
                    )]));
                }
                Ok(Some(vec![Event::RawEmgState(pending.enabled)]))
            }
        }
    }
}

/// The band's DeviceInfoResp (Meta AI's schema): its firmware and serial number.
#[derive(Clone, Default, PartialEq)]
pub struct DeviceInfo {
    pub firmware: String,
    pub software: String,
    pub hardware: String,
    pub serial: String,
    pub release_branch: String,
    /// The EMG model the band runs now (`DeviceInfoResp.modelId`): `cc_od_…` for gestures,
    /// `ia_od_…` for the wake model of a band in standby.
    pub model: String,
    /// Every model on the band (`allModelIds`); a `hw_…` one means it reads handwriting
    /// (firmware build 64 and later; the factory firmware has none).
    pub models: Vec<String>,
}

impl DeviceInfo {
    /// Whether the band's firmware has a handwriting model.
    pub fn handwriting(&self) -> bool {
        self.models.iter().any(|model| model.starts_with("hw_"))
    }
}

/// Leaves the serial out.
impl std::fmt::Debug for DeviceInfo {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("DeviceInfo")
            .field("firmware", &self.firmware)
            .field("software", &self.software)
            .field("hardware", &self.hardware)
            .finish_non_exhaustive()
    }
}

impl DeviceInfo {
    /// The DeviceInfoResp inside an RPC response: the nested message with a printable serial
    /// (field 6) and a firmware revision (2).
    fn find(fields: &ProtoFields, depth: usize) -> Option<Self> {
        let serial = fields.text(6).filter(|s| (4..=64).contains(&s.len()) && s.bytes().all(|b| b.is_ascii_alphanumeric()));
        if let (Some(serial), Some(firmware)) = (serial, fields.text(2)) {
            return Some(Self {
                firmware,
                software: fields.text(3).unwrap_or_default(),
                hardware: fields.text(4).unwrap_or_default(),
                serial,
                release_branch: fields.text(13).unwrap_or_default(),
                model: fields.text(5).unwrap_or_default(),
                models: fields
                    .byte_fields()
                    .into_iter()
                    .filter(|(field, _)| *field == 10)
                    .filter_map(|(_, bytes)| std::str::from_utf8(bytes).ok().map(str::to_owned))
                    .collect(),
            });
        }
        if depth >= 3 {
            return None;
        }
        fields
            .byte_fields()
            .into_iter()
            .find_map(|(_, bytes)| ProtoFields::parse(bytes).ok().and_then(|inner| Self::find(&inner, depth + 1)))
    }
}

#[cfg(test)]
mod device_info_tests {
    use super::*;
    use crate::proto::{field_bytes, field_int};

    #[test]
    fn device_info_is_found_inside_the_response() {
        let info = [field_bytes(2, b"1.2.3"), field_bytes(4, b"PVT"), field_bytes(6, b"ABC123XYZ")].concat();
        let response = [field_int(1, 1), field_int(2, 1), field_bytes(3, &field_bytes(5, &info))].concat();
        let found = DeviceInfo::find(&ProtoFields::parse(&response).unwrap(), 0).unwrap();
        assert_eq!((found.firmware.as_str(), found.hardware.as_str(), found.serial.as_str()), ("1.2.3", "PVT", "ABC123XYZ"));
    }
}

/// The `ConfigReq` that turns the band's handwriting on (HANDWRITING_CC, standby fields off) or
/// off (ACTIVE; neural-playground: with the standby fields as the config read found them, so the
/// band can save power again).
fn handwriting_config(on: bool, saved: Option<&[(u32, u64)]>) -> Vec<u8> {
    if on {
        return [field_int(6, 4), HANDWRITING_OFF_FIELDS.iter().flat_map(|&field| field_int(field, 0)).collect()].concat();
    }
    let restore: Vec<u8> = saved.unwrap_or_default().iter().flat_map(|&(field, value)| field_int(field, value)).collect();
    [field_int(6, 2), restore].concat()
}

#[cfg(test)]
mod power_tests {
    use super::*;

    #[test]
    fn handwriting_off_restores_the_standby_fields_it_turned_off() {
        assert_eq!(handwriting_config(true, None), [field_int(6, 4), field_int(13, 0), field_int(21, 0)].concat());
        assert_eq!(handwriting_config(false, None), field_int(6, 2));
        assert_eq!(
            handwriting_config(false, Some(&[(13, 1), (21, 30)])),
            [field_int(6, 2), field_int(13, 1), field_int(21, 30)].concat()
        );
    }

    #[test]
    fn motion_follows_the_caller_and_waits_for_the_streams() {
        let mut session = BandSession::new(None, None, false).without_motion();
        assert!(!session.motion_on());
        // Before the streams are up the setting only changes what the subscription asks for.
        assert_eq!(session.set_motion(true).unwrap(), Vec::<u8>::new());
        assert!(session.motion_on());
        session.setup_stage = SetupStage::Input;
        session.streams_enabled = true;
        session.transmitter = Some(AirShieldCipher::new(AirShieldKeys::fixed([1; 32], [2; 32]), [0; 16], 0));
        assert!(!session.set_motion(false).unwrap().is_empty());
        assert!(!session.motion_on());
        assert_eq!(session.set_motion(false).unwrap(), Vec::<u8>::new());
    }
}

#[cfg(test)]
mod haptics_serialization_tests {
    use super::*;
    use crate::ota::OtaMode;

    fn ready() -> BandSession {
        let mut session = BandSession::new(None, None, false);
        session.setup_stage = SetupStage::Input;
        session.streams_enabled = true;
        session
    }

    fn plan() -> OtaPlan {
        OtaPlan { version: 0, firmware: Vec::new(), firmware_md5: [0; 16], model: None, kek: None, mode: OtaMode::Cancel, resume: false }
    }

    fn blocked(session: &mut BandSession) {
        let sequence = session.configuration_id;
        assert!(!session.haptics_ready());
        assert!(matches!(session.send_haptics(HapticsCommand::Vibrate { duration_ms: 80, amplitude: 255 }, 1.0), Err(BandError::Busy(_))));
        assert_eq!(session.configuration_id, sequence);
        assert!(session.haptics_request.is_none());
    }

    #[test]
    fn haptics_wait_for_other_requests_and_the_entire_firmware_job() {
        let mut session = ready();
        assert!(session.haptics_ready());
        session.ota_request = Some((3, 5.0));
        blocked(&mut session);
        session.ota_request = None;
        session.ota_job = Some(OtaJob::new(plan()));
        blocked(&mut session);
        session.ota_job = None;
        session.raw_request = Some(RawRequest { enabled: true, stage: RawStage::Config, id: 4, deadline: 5.0 });
        blocked(&mut session);
        session.raw_request = None;
        session.hand_request = Some(HandRequest { id: 5, hand: None, reading: true, deadline: 5.0, probe: false });
        blocked(&mut session);
        session.hand_request = None;
        session.battery_request = Some((6, 5.0));
        blocked(&mut session);
        session.battery_request = None;
        session.configuration_requests.push((7, 5.0));
        blocked(&mut session);
        session.tick(5.0);
        assert!(session.haptics_ready());
    }

    #[test]
    fn an_unanswered_update_status_expires_and_releases_haptics() {
        let mut session = ready();
        session.transmitter = Some(AirShieldCipher::new(AirShieldKeys::fixed([1; 32], [2; 32]), [0; 16], 0));
        session.tick(1.0);
        session.ota_status().unwrap();
        session.take_diagnostics();
        session.tick(5.9);
        assert!(!session.haptics_ready());
        session.tick(6.0);
        assert!(session.haptics_ready());
        assert_eq!(session.take_diagnostics(), ["ota: the band didn't answer the update status request"]);
    }

    #[test]
    fn only_the_matching_configuration_response_releases_haptics() {
        let mut session = ready();
        session.configuration_requests.push((10, 5.0));
        session.configuration_requests.push((10, 5.0));
        for (id, ready) in [(9, false), (10, false), (10, true)] {
            let frame = DataXFrame { channel: CONFIGURATION_CHANNEL, words: vec![RPC_RESPONSE], payload: [field_int(1, id), field_int(2, 1)].concat() };
            session.input(&frame, 1.0, &mut Vec::new()).unwrap();
            assert_eq!(session.haptics_ready(), ready);
        }
    }

    #[test]
    fn firmware_cannot_start_before_a_haptics_response() {
        let mut session = ready();
        session.haptics_request = Some((1, 5.0, 2));
        assert!(matches!(session.ota_start(plan(), 1.0), Err(BandError::Busy(_))));
        assert!(session.ota_job.is_none());
    }
}
