// SPDX-License-Identifier: GPL-2.0-or-later
//! Pairing with an Apple Vision Pro as the host that starts it.
//!
//! iOS 27 pairs by finding a "pairable host" and connecting to it; Husk's rppairing library plays that host. visionOS
//! does it the other way round, as tvOS does: with Settings > General > Remote Devices open, the headset advertises
//! `_remotepairing-manual-pairing._tcp`, the host connects and asks to pair, the headset shows a code, and the host
//! sends it back. This is that host, on idevice's `RemotePairingClient` (MIT, jkcoxson/idevice).
//!
//! The Rust interface is for `henge-pair` on a Mac; the C one is for the visionOS app, where the address is the
//! headset's own (through Henge's loopback tunnel: it resets a connection that comes from itself).
use idevice::remote_pairing::{RemotePairingClient, RpPairingFile, RpPairingSocket};
use std::ffi::{CStr, CString, c_char, c_void};
use std::future::Future;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

/// What went wrong, or that the caller gave no code.
pub enum Failure {
    Cancelled,
    Error(String),
}

/// Pairs as `host` with the device at `address` (`ip:port` of its manual pairing service) and returns the pairing
/// file. `code` is asked once the device shows its code; `None` from it cancels.
pub async fn pair<F, Fut>(address: &str, host: &str, code: F) -> Result<RpPairingFile, Failure>
where
    F: Fn() -> Fut,
    Fut: Future<Output = Option<String>>,
{
    let stream = tokio::net::TcpStream::connect(address)
        .await
        .map_err(|e| Failure::Error(format!("could not connect to {address}: {e}")))?;
    let mut file = RpPairingFile::generate(host);
    let mut client = RemotePairingClient::new(RpPairingSocket::new(stream), host);
    let cancelled = Arc::new(AtomicBool::new(false));
    let result = client
        .connect(&mut file, || {
            let cancelled = cancelled.clone();
            let asked = code();
            async move {
                // An empty code fails the exchange, which ends it: the flag says it was the caller's choice.
                asked.await.unwrap_or_else(|| {
                    cancelled.store(true, Ordering::SeqCst);
                    String::new()
                })
            }
        })
        .await;
    match result {
        Ok(()) => Ok(file),
        Err(_) if cancelled.load(Ordering::SeqCst) => Err(Failure::Cancelled),
        Err(e) => Err(Failure::Error(format!("{e:?}"))),
    }
}

/// Whether the device at `address` (its `_remotepairing._tcp` service) still accepts the pairing in `file`.
pub async fn verify(address: &str, file: &mut RpPairingFile) -> Result<(), String> {
    let stream = tokio::net::TcpStream::connect(address)
        .await
        .map_err(|e| format!("could not connect to {address}: {e}"))?;
    let mut client = RemotePairingClient::new(RpPairingSocket::new(stream), "Henge");
    client.attempt_pair_verify().await.map_err(|e| format!("pair-verify did not start: {e:?}"))?;
    client.validate_pairing(file).await.map(|_| ()).map_err(|e| format!("{e:?}"))
}

// ---------------------------------------------------------------- C interface (ios/Henge/Vision/HengeRPClient.h)

unsafe extern "C" {
    fn free(pointer: *mut c_void);
}

/// The code the device shows, as a C string made with malloc (this library frees it), or NULL to cancel. Called on
/// the thread that called `henge_rpclient_pair`, and may block for as long as the person needs.
pub type HengeRPClientCode = unsafe extern "C" fn(context: *mut c_void) -> *mut c_char;

fn set_error(out: *mut *mut c_char, message: String) {
    if out.is_null() {
        return;
    }
    let text = CString::new(message.replace('\0', " ")).unwrap_or_default();
    unsafe { *out = text.into_raw() };
}

/// Blocks until paired (0, with the pairing file in `*out_plist`/`*out_len`), failed (1, `*error` set) or
/// cancelled (2). Free the file with `henge_rpclient_bytes_free` and the error with `henge_rpclient_string_free`.
///
/// # Safety
/// `address` and `host_name` must be C strings; the out pointers must be valid or NULL.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn henge_rpclient_pair(
    address: *const c_char,
    port: u16,
    host_name: *const c_char,
    code: Option<HengeRPClientCode>,
    context: *mut c_void,
    out_plist: *mut *mut u8,
    out_len: *mut usize,
    error: *mut *mut c_char,
) -> i32 {
    if address.is_null() || host_name.is_null() || out_plist.is_null() || out_len.is_null() {
        set_error(error, "henge_rpclient_pair: missing argument".into());
        return 1;
    }
    let (Some(code), Ok(address), Ok(host)) = (
        code,
        unsafe { CStr::from_ptr(address) }.to_str(),
        unsafe { CStr::from_ptr(host_name) }.to_str(),
    ) else {
        set_error(error, "henge_rpclient_pair: bad argument".into());
        return 1;
    };
    let runtime = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
        Ok(runtime) => runtime,
        Err(e) => {
            set_error(error, format!("could not start the pairing runtime: {e}"));
            return 1;
        }
    };
    let context = context as usize; // the pointer is only handed back to the caller's function
    let target = format!("{address}:{port}");
    let ask = move || async move {
        let pointer = unsafe { code(context as *mut c_void) };
        if pointer.is_null() {
            return None;
        }
        let text = unsafe { CStr::from_ptr(pointer) }.to_string_lossy().trim().to_string();
        unsafe { free(pointer as *mut c_void) };
        Some(text)
    };
    match runtime.block_on(pair(&target, host, ask)) {
        Ok(file) => {
            let bytes = file.to_bytes().into_boxed_slice();
            unsafe {
                *out_len = bytes.len();
                *out_plist = Box::into_raw(bytes) as *mut u8;
            }
            0
        }
        Err(Failure::Cancelled) => 2,
        Err(Failure::Error(message)) => {
            set_error(error, message);
            1
        }
    }
}

/// # Safety
/// `bytes`/`len` must come from `henge_rpclient_pair`, or `bytes` be NULL.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn henge_rpclient_bytes_free(bytes: *mut u8, len: usize) {
    if !bytes.is_null() {
        drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(bytes, len)) });
    }
}

/// # Safety
/// `string` must come from this library, or be NULL.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn henge_rpclient_string_free(string: *mut c_char) {
    if !string.is_null() {
        drop(unsafe { CString::from_raw(string) });
    }
}
