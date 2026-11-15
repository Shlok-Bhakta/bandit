//! The gesture profile set (../np-profiles, PROFILES.md): the built-in one, or a file the app sent,
//! kept in NVS. `profiles begin|data|commit|reset` over the control service replace it, and
//! `profiles show` logs it back; they run in order on one worker (`enqueue`), unlike other
//! commands, which each get a thread of their own.

use std::sync::mpsc::{sync_channel, SyncSender, TrySendError};
use std::sync::{Arc, Mutex, OnceLock, RwLock};

use base64::Engine;
use esp_idf_svc::nvs::{EspNvs, NvsDefault};
use log::{info, warn};
use np_profiles::{ProfileSet, MAX_BYTES};
use sha2::{Digest, Sha256};

use crate::remote::Remote;

const NVS_KEY: &str = "profiles";

struct Current {
    set: Arc<ProfileSet>,
    /// "builtin", or the first 8 hex digits of the stored file's SHA-256.
    hash: String,
}

static CURRENT: RwLock<Option<Current>> = RwLock::new(None);
/// Why the last upload was refused (the status shows it until one is saved).
static ERROR: Mutex<Option<String>> = Mutex::new(None);
static UPLOAD: Mutex<Option<Upload>> = Mutex::new(None);

static QUEUE: Mutex<Option<SyncSender<String>>> = Mutex::new(None);

struct Upload {
    bytes: Vec<u8>,
    /// Which bytes have arrived (the app may send chunks in any order), a bit each.
    filled: Vec<u32>,
    sha8: String,
}

impl Upload {
    fn fill(&mut self, range: std::ops::Range<usize>) {
        for i in range { self.filled[i / 32] |= 1 << (i % 32); }
    }

    fn missing(&self) -> usize { (0..self.bytes.len()).filter(|i| self.filled[i / 32] & (1 << (i % 32)) == 0).count() }
}

/// The stored file, read straight into a buffer its size.
fn stored(nvs: &EspNvs<NvsDefault>) -> Option<Vec<u8>> {
    let len = nvs.blob_len(NVS_KEY).ok().flatten()?;
    let mut bytes = vec![0u8; len];
    let read = nvs.get_blob(NVS_KEY, &mut bytes).ok().flatten()?.len();
    bytes.truncate(read);
    Some(bytes)
}

/// Keeps what the worker needs: `profiles …` commands run one at a time, in the order they arrive
/// (checking a whole file needs more stack than a command thread has).
pub fn start(remote: Remote) { let _ = REMOTE.set(remote); }

static REMOTE: OnceLock<Remote> = OnceLock::new();

/// Queues `rest` of a `profiles …` command for the worker; call it where commands arrive, so
/// their order is kept. The worker runs only while there are commands: it starts with the first
/// and ends after `IDLE` without one. Checking a file took 4.9 KB of stack (0.15.1, 5 deep; np-profiles
/// refuses files over 12 deep before parsing, and 120 deep once overflowed 24 KB).
pub fn enqueue(rest: &str) {
    let mut queue = QUEUE.lock().unwrap();
    if let Some(sender) = queue.as_ref() {
        match sender.try_send(rest.to_string()) {
            Ok(()) => return,
            Err(TrySendError::Full(_)) => return refuse("too many profile commands at once".into()),
            Err(TrySendError::Disconnected(_)) => *queue = None,
        }
    }
    let Some(remote) = REMOTE.get().cloned() else { return refuse("not ready".into()) };
    let (sender, receiver) = sync_channel::<String>(64);
    let _ = sender.try_send(rest.to_string());
    let spawned = crate::memory::spawn(c"profiles", 12 * 1024, move || loop {
        match receiver.recv_timeout(IDLE) {
            Ok(line) => command(&remote, &line),
            Err(_) => {
                // Gone only with nothing queued: `enqueue` sends under this lock.
                let mut queue = QUEUE.lock().unwrap();
                if let Ok(line) = receiver.try_recv() { drop(queue); command(&remote, &line); continue; }
                *queue = None;
                drop(queue);
                info!("PROFILES: worker idle, ending ({} B of its stack never used)", crate::memory::own_stack_unused());
                return;
            }
        }
    });
    match spawned {
        Ok(_) => *queue = Some(sender),
        Err(error) => refuse(format!("couldn't start ({error})")),
    }
}

/// How long the worker waits for another command before it ends.
const IDLE: std::time::Duration = std::time::Duration::from_secs(20);

fn sha8(bytes: &[u8]) -> String { Sha256::digest(bytes)[..4].iter().map(|b| format!("{b:02x}")).collect() }

/// The stored set, or the built-in one if there's none (or it no longer reads).
pub fn load(nvs: &EspNvs<NvsDefault>) {
    let current = match stored(nvs).map(|bytes| (ProfileSet::parse(&String::from_utf8_lossy(&bytes)), sha8(&bytes))) {
        Some((Ok(set), hash)) => {
            info!("PROFILES: \"{}\" ({} profiles, {hash})", set.name, set.profiles.len());
            Current { set: Arc::new(set), hash }
        }
        Some((Err(error), _)) => {
            warn!("PROFILES: the stored set doesn't read ({error}); using the built-in one");
            builtin()
        }
        None => builtin(),
    };
    *CURRENT.write().unwrap() = Some(current);
}

fn builtin() -> Current { Current { set: Arc::new(ProfileSet::builtin()), hash: "builtin".into() } }

pub fn current() -> Arc<ProfileSet> {
    CURRENT.read().unwrap().as_ref().map(|c| c.set.clone()).unwrap_or_else(|| Arc::new(ProfileSet::builtin()))
}

pub fn hash() -> String { CURRENT.read().unwrap().as_ref().map(|c| c.hash.clone()).unwrap_or_else(|| "builtin".into()) }

pub fn error() -> Option<String> { ERROR.lock().unwrap().clone() }

fn refuse(message: String) {
    warn!("PROFILES: refused: {message}");
    *ERROR.lock().unwrap() = Some(message);
}

/// `profiles begin <bytes> <sha8>` · `profiles data <offset> <base64>` · `profiles commit` · `profiles reset` · `profiles show`.
fn command(remote: &Remote, rest: &str) {
    let nvs = remote.nvs();
    let mut words = rest.split_whitespace();
    match (words.next(), words.next(), words.next()) {
        (Some("begin"), Some(len), Some(sha)) => match len.parse::<usize>() {
            Ok(len) if (1..=MAX_BYTES).contains(&len) && sha.len() == 8 => {
                *UPLOAD.lock().unwrap() = Some(Upload { bytes: vec![0; len], filled: vec![0; len.div_ceil(32)], sha8: sha.to_ascii_lowercase() });
                info!("PROFILES: receiving {len} bytes");
            }
            _ => refuse(format!("profiles begin <1-{MAX_BYTES} bytes> <8 hex digits of its SHA-256>")),
        },
        (Some("data"), Some(offset), Some(encoded)) => {
            let (Ok(offset), Ok(chunk)) = (offset.parse::<usize>(), base64::engine::general_purpose::STANDARD.decode(encoded)) else {
                return refuse("profiles data <offset> <base64>".into());
            };
            let mut upload = UPLOAD.lock().unwrap();
            let Some(upload) = upload.as_mut() else { return refuse("data before profiles begin".into()) };
            let Some(end) = offset.checked_add(chunk.len()).filter(|end| *end <= upload.bytes.len()) else {
                return refuse(format!("data past the {} bytes begun", upload.bytes.len()));
            };
            upload.bytes[offset..end].copy_from_slice(&chunk);
            upload.fill(offset..end);
        }
        (Some("commit"), None, None) => commit(remote, nvs),
        (Some("show"), None, None) => show(nvs),
        (Some("reset"), None, None) => {
            *UPLOAD.lock().unwrap() = None;
            let _ = nvs.lock().unwrap().remove(NVS_KEY);
            *CURRENT.write().unwrap() = Some(builtin());
            *ERROR.lock().unwrap() = None;
            info!("PROFILES: back to the built-in set");
            remote.profiles_changed();
        }
        _ => warn!("CONTROL: profiles begin <bytes> <sha8> | profiles data <offset> <base64> | profiles commit | profiles reset | profiles show"),
    }
}

/// The set the dongle runs, as the file it was sent as (the built-in one's own JSON with none),
/// in log lines a reader puts back together: `PROFILES: show begin <bytes> <sha8> [builtin]`, then
/// `PROFILES: show data <offset> <base64>` and `PROFILES: show end`. Paced, so the app's log
/// stream (4 KB a quarter second) keeps every line.
fn show(nvs: &Mutex<EspNvs<NvsDefault>>) {
    let stored = stored(&nvs.lock().unwrap());
    let builtin = stored.is_none();
    let bytes: std::borrow::Cow<[u8]> = stored.map_or(np_profiles::DEFAULT_JSON.as_bytes().into(), Into::into);
    info!("PROFILES: show begin {} {}{}", bytes.len(), sha8(&bytes), if builtin { " builtin" } else { "" });
    for (i, chunk) in bytes.chunks(150).enumerate() {
        info!("PROFILES: show data {} {}", i * 150, base64::engine::general_purpose::STANDARD.encode(chunk));
        std::thread::sleep(std::time::Duration::from_millis(40));
    }
    info!("PROFILES: show end");
}

fn commit(remote: &Remote, nvs: &Mutex<EspNvs<NvsDefault>>) {
    let Some(upload) = UPLOAD.lock().unwrap().take() else { return refuse("commit before profiles begin".into()) };
    let missing = upload.missing();
    if missing > 0 { return refuse(format!("{missing} bytes never arrived")); }
    let hash = sha8(&upload.bytes);
    if hash != upload.sha8 { return refuse(format!("the bytes hash to {hash}, not {}", upload.sha8)); }
    let text = match String::from_utf8(upload.bytes) { Ok(text) => text, Err(_) => return refuse("not UTF-8".into()) };
    let set = match ProfileSet::parse(&text) { Ok(set) => set, Err(error) => return refuse(error.to_string()) };
    if let Err(error) = nvs.lock().unwrap().set_blob(NVS_KEY, text.as_bytes()) {
        return refuse(format!("couldn't save it ({error})"));
    }
    info!("PROFILES: saved \"{}\" ({} profiles, {} bytes, {hash})", set.name, set.profiles.len(), text.len());
    *CURRENT.write().unwrap() = Some(Current { set: Arc::new(set), hash });
    *ERROR.lock().unwrap() = None;
    remote.profiles_changed();
}
