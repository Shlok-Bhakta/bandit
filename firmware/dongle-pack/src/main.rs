//! dongle-pack: signs band-dongle firmware for over-the-air updates (see ../band-dongle/CONTROL.md).
//!
//! `dongle-pack keygen`
//!     Creates the ECDSA P-256 signing key (outside the repo, owner-only) and prints its public half
//!     for band-dongle's src/ota.rs.
//! `dongle-pack pack <app.bin> <out-dir> [--notes TEXT] [--version V] [--bootloader B --partitions P --esptool JS]`
//!     Writes `band-dongle-<id>.npfw` and `latest.json`; with the three flasher inputs, also a
//!     self-contained Chrome (Web Serial) flasher page (esptool-js 0.7 `bundle.js`) that writes the bootloader, the partition
//!     table, a blank otadata (boot ota_0) and the app, leaving NVS (owner key, pairings) alone.

use std::path::{Path, PathBuf};

use anyhow::{bail, ensure, Context};
use base64::Engine;
use p256::ecdsa::signature::{Signer, Verifier};
use p256::ecdsa::{Signature, SigningKey, VerifyingKey};
use sha2::{Digest, Sha256};

const MAGIC: &[u8; 8] = b"NPDFW\x01\x00\x00";
const HEADER_LEN: usize = 256;

fn key_path() -> anyhow::Result<PathBuf> {
    let home = std::env::var("HOME").context("HOME isn't set")?;
    Ok(PathBuf::from(home).join(".config/neural-playground/dongle-signing.key"))
}

fn load_key() -> anyhow::Result<SigningKey> {
    let path = key_path()?;
    let text = std::fs::read_to_string(&path).with_context(|| format!("no signing key at {} (run `dongle-pack keygen`)", path.display()))?;
    let secret = hex_decode(text.trim())?;
    ensure!(secret.len() == 32, "the signing key file must hold a 32-byte hex P-256 secret");
    Ok(SigningKey::from_slice(&secret)?)
}

fn keygen() -> anyhow::Result<()> {
    let path = key_path()?;
    if path.exists() {
        bail!("{} already exists; refusing to replace the key the dongle trusts", path.display());
    }
    std::fs::create_dir_all(path.parent().unwrap())?;
    let key = SigningKey::random(&mut rand_core::OsRng);
    let hex = hex_encode(&key.to_bytes());
    {
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        let mut file = std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&path)?;
        writeln!(file, "{hex}")?;
    }
    println!("Signing key written to {} (owner-only). Public key for src/ota.rs:", path.display());
    println!("{}", rust_array(VerifyingKey::from(&key).to_encoded_point(false).as_bytes()));
    Ok(())
}

/// The ESP32 app image's `esp_app_desc_t` sits after the 24-byte image header and the first
/// 8-byte segment header: magic, then version (32 bytes) at +16 and the ELF SHA-256 at +144.
fn app_identity(image: &[u8]) -> anyhow::Result<(String, String)> {
    ensure!(image.len() > 32 + 176 && image[0] == 0xE9, "that isn't an ESP32 app image");
    let desc = &image[32..];
    ensure!(desc[..4] == 0xABCD5432u32.to_le_bytes(), "no app description in the image");
    let text = |bytes: &[u8]| String::from_utf8_lossy(bytes.split(|&b| b == 0).next().unwrap_or_default()).into_owned();
    Ok((text(&desc[16..48]), hex_encode(&desc[144..148])))
}

fn pack(args: &[String]) -> anyhow::Result<()> {
    let (Some(app), Some(out)) = (args.first(), args.get(1)) else {
        bail!("usage: dongle-pack pack <app.bin> <out-dir> [--notes TEXT] [--version V] [--bootloader B --partitions P --esptool JS]")
    };
    let option = |name: &str| args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).cloned();
    let image = std::fs::read(app).with_context(|| format!("reading {app}"))?;
    let (built_version, id) = app_identity(&image)?;
    let version = option("--version").unwrap_or(built_version);
    let key = load_key()?;

    let mut header = [0u8; HEADER_LEN];
    header[..8].copy_from_slice(MAGIC);
    header[8..12].copy_from_slice(&(image.len() as u32).to_le_bytes());
    let label = format!("{version} {id}");
    let label = &label.as_bytes()[..label.len().min(47)];
    header[16..16 + label.len()].copy_from_slice(label);
    header[64..96].copy_from_slice(&Sha256::digest(&image));
    let signature: Signature = key.sign(&header[..96]);
    header[96..160].copy_from_slice(&signature.to_bytes());
    VerifyingKey::from(&key).verify(&header[..96], &signature)?;

    let out = Path::new(out);
    std::fs::create_dir_all(out)?;
    let file = format!("band-dongle-{id}.npfw");
    let package = [&header[..], &image].concat();
    std::fs::write(out.join(&file), &package)?;

    let flasher = match (option("--bootloader"), option("--partitions"), option("--esptool")) {
        (Some(bootloader), Some(partitions), Some(esptool)) => {
            let name = format!("band-dongle-{id}-flasher.html");
            let page = flasher_page(&std::fs::read(bootloader)?, &std::fs::read(partitions)?, &image, &std::fs::read_to_string(esptool)?, &label_text(label));
            std::fs::write(out.join(&name), page)?;
            Some(name)
        }
        (None, None, None) => None,
        _ => bail!("the flasher needs all of --bootloader, --partitions and --esptool"),
    };

    let notes = option("--notes").unwrap_or_default();
    let index = format!(
        "{{\"version\":{},\"id\":{},\"file\":{},\"size\":{},\"sha256\":{},\"notes\":{}{}}}\n",
        json(&version), json(&id), json(&file), package.len(), json(&hex_encode(&Sha256::digest(&package))), json(&notes),
        flasher.as_ref().map(|name| format!(",\"flasher\":{}", json(name))).unwrap_or_default(),
    );
    std::fs::write(out.join("latest.json"), &index)?;
    println!("{file}: {} bytes, version {version}, id {id}", package.len());
    if let Some(name) = flasher { println!("{name}"); }
    print!("latest.json: {index}");
    Ok(())
}

fn label_text(label: &[u8]) -> String { String::from_utf8_lossy(label).into_owned() }

/// One HTML file, no network needed: esptool-js and the four images are inlined.
fn flasher_page(bootloader: &[u8], partitions: &[u8], app: &[u8], esptool: &str, label: &str) -> String {
    let b64 = |bytes: &[u8]| base64::engine::general_purpose::STANDARD.encode(bytes);
    let esptool = b64(esptool.as_bytes());
    format!(r#"<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>NP Band Remote flasher</title>
<style>
body{{font:16px -apple-system,system-ui,sans-serif;max-width:640px;margin:40px auto;padding:0 20px;color:#111}}
button{{font-size:17px;padding:10px 18px;border-radius:10px;border:0;background:#2563eb;color:#fff;cursor:pointer}}
button:disabled{{background:#9ca3af}} progress{{width:100%;height:14px}}
pre{{background:#f3f4f6;padding:12px;border-radius:8px;height:220px;overflow:auto;font-size:12px;white-space:pre-wrap}}
</style></head><body>
<h1>NP Band Remote flasher</h1>
<p>Firmware <b>{label}</b>. Use desktop Chrome or Edge. Plug the dongle in over USB, press <b>Flash</b>, then pick the
dongle's port (usually "USB JTAG/serial debug unit"). This writes the firmware and keeps the dongle's owner key and
Bluetooth pairings. If the port doesn't appear: unplug, hold the BOOT button (G0 on a Cardputer) while plugging back in, release, and try again.</p>
<p><button id="go">Flash</button></p>
<progress id="bar" value="0" max="1"></progress>
<pre id="log"></pre>
<script type="module">
const esptool = await import(URL.createObjectURL(new Blob([atob("{esptool}")], {{type: "text/javascript"}})));
const bytes = s => Uint8Array.from(atob(s), c => c.charCodeAt(0));
const parts = [
  ["bootloader", 0x0, bytes("{bootloader}")],
  ["partition table", 0x8000, bytes("{partitions}")],
  ["otadata (boot ota_0)", 0xf000, new Uint8Array(0x2000).fill(0xff)],
  ["firmware", 0x20000, bytes("{app}")],
];
const log = document.getElementById("log"), bar = document.getElementById("bar"), go = document.getElementById("go");
const say = text => {{ log.textContent += text + "\n"; log.scrollTop = log.scrollHeight; }};
const terminal = {{ clean() {{}}, writeLine: say, write: t => {{ log.textContent += t; }} }};
if (!("serial" in navigator)) {{ say("This browser has no Web Serial: use desktop Chrome or Edge."); go.disabled = true; }}
go.onclick = async () => {{
  go.disabled = true;
  try {{
    const port = await navigator.serial.requestPort();
    const transport = new esptool.Transport(port, true);
    const loader = new esptool.ESPLoader({{ transport, baudrate: 460800, terminal }});
    say("Connected to " + await loader.main());
    const fileArray = parts.map(([, address, data]) => ({{ address, data }}));
    await loader.writeFlash({{ fileArray, flashSize: "keep", flashMode: "keep", flashFreq: "keep", eraseAll: false, compress: true,
      reportProgress: (index, written, total) => {{ bar.value = (index + written / total) / fileArray.length; }} }});
    bar.value = 1;
    say("Done. Restarting the dongle.");
    await loader.after("hard_reset");
    await transport.disconnect();
    say("Flashed. Unplug and replug if it doesn't start within a few seconds.");
  }} catch (error) {{ say("Failed: " + (error.message || error)); }}
  go.disabled = false;
}};
</script></body></html>
"#,
        bootloader = b64(bootloader), partitions = b64(partitions), app = b64(app))
}

fn json(text: &str) -> String {
    let mut out = String::from("\"");
    for c in text.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

fn hex_encode(bytes: &[u8]) -> String { bytes.iter().map(|b| format!("{b:02x}")).collect() }

fn hex_decode(text: &str) -> anyhow::Result<Vec<u8>> {
    ensure!(text.len() % 2 == 0, "odd-length hex");
    (0..text.len()).step_by(2).map(|i| Ok(u8::from_str_radix(&text[i..i + 2], 16)?)).collect()
}

fn rust_array(bytes: &[u8]) -> String {
    let body = bytes.chunks(16).map(|row| row.iter().map(|b| format!("0x{b:02x}")).collect::<Vec<_>>().join(", ")).collect::<Vec<_>>().join(",\n    ");
    format!("const UPDATE_KEY: [u8; {}] = [\n    {body},\n];", bytes.len())
}

fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("keygen") => keygen(),
        Some("pack") => pack(&args[1..]),
        _ => bail!("usage: dongle-pack keygen | dongle-pack pack <app.bin> <out-dir> [--notes TEXT] [--version V] [--bootloader B --partitions P --esptool JS]"),
    }
}
