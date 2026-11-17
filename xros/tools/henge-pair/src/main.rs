// SPDX-License-Identifier: GPL-2.0-or-later
//! henge-pair ADDRESS:PORT OUT.plist [CODE_FILE] [HOST_NAME]
//! henge-pair --verify ADDRESS:PORT FILE.plist
//!
//! Pairs a Mac-side host identity with an Apple Vision Pro, the way Xcode does, and writes the remote pairing file
//! (see lib.rs). ADDRESS:PORT is the headset's `_remotepairing-manual-pairing._tcp` service, which it advertises
//! while Settings > General > Remote Devices is open: dns-sd -L "<name>" _remotepairing-manual-pairing._tcp
//!
//! The code is typed at the prompt, or, with CODE_FILE, read from that file once it exists (for a caller that learns
//! the code later than it starts this). --verify checks a pairing file against the headset's `_remotepairing._tcp`.
use henge_rpclient::{Failure, pair, verify};
use idevice::remote_pairing::RpPairingFile;
use std::io::Write;
use std::time::Duration;

async fn read_code(code_file: Option<String>) -> Option<String> {
    match code_file {
        Some(path) => {
            eprintln!("henge-pair: the headset should show a code now; waiting for it in {path}");
            loop {
                if let Ok(text) = std::fs::read_to_string(&path) {
                    let code = text.trim().to_string();
                    if !code.is_empty() {
                        eprintln!("henge-pair: code received");
                        return Some(code);
                    }
                }
                tokio::time::sleep(Duration::from_millis(300)).await;
            }
        }
        None => {
            eprint!("Code shown on the headset: ");
            std::io::stderr().flush().ok();
            let mut line = String::new();
            std::io::stdin().read_line(&mut line).ok();
            let code = line.trim().to_string();
            if code.is_empty() { None } else { Some(code) }
        }
    }
}

#[tokio::main(flavor = "current_thread")]
async fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() == 4 && args[1] == "--verify" {
        let checked = match std::fs::read(&args[3]).map_err(|e| e.to_string()).and_then(|bytes| {
            RpPairingFile::from_bytes(&bytes).map_err(|e| format!("not a pairing file: {e:?}"))
        }) {
            Ok(mut file) => verify(&args[2], &mut file).await,
            Err(e) => Err(e),
        };
        match checked {
            Ok(()) => eprintln!("henge-pair: the headset accepts this pairing"),
            Err(e) => {
                eprintln!("henge-pair: the headset does not accept this pairing: {e}");
                std::process::exit(1);
            }
        }
        return;
    }
    if args.len() < 3 {
        eprintln!("usage: henge-pair ADDRESS:PORT OUT.plist [CODE_FILE] [HOST_NAME]\n       henge-pair --verify ADDRESS:PORT FILE.plist");
        std::process::exit(2);
    }
    let (address, out) = (&args[1], &args[2]);
    let code_file = args.get(3).filter(|s| !s.is_empty()).cloned();
    let host = args.get(4).cloned().unwrap_or_else(|| "Henge".to_string());

    eprintln!("henge-pair: asking {address} to pair as \"{host}\"");
    match pair(address, &host, || read_code(code_file.clone())).await {
        Ok(file) => {
            if let Err(e) = std::fs::write(out, file.to_bytes()) {
                eprintln!("henge-pair: paired, but could not write {out}: {e}");
                std::process::exit(1);
            }
            eprintln!("henge-pair: paired; pairing file written to {out}");
        }
        Err(Failure::Cancelled) => {
            eprintln!("henge-pair: cancelled");
            std::process::exit(1);
        }
        Err(Failure::Error(e)) => {
            eprintln!("henge-pair: pairing failed: {e}");
            std::process::exit(1);
        }
    }
}
