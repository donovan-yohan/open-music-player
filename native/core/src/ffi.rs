use crate::{Command, Core};
use std::{
    collections::HashMap,
    ffi::{CStr, CString, c_char},
    panic::{AssertUnwindSafe, catch_unwind},
    path::PathBuf,
    sync::{
        Arc, Mutex, OnceLock,
        atomic::{AtomicU64, Ordering},
    },
};

static HANDLES: OnceLock<Mutex<HashMap<u64, Arc<Core>>>> = OnceLock::new();
static NEXT: AtomicU64 = AtomicU64::new(1);
fn handles() -> &'static Mutex<HashMap<u64, Arc<Core>>> {
    HANDLES.get_or_init(|| Mutex::new(HashMap::new()))
}
fn get(id: u64) -> Option<Arc<Core>> {
    handles().lock().ok()?.get(&id).cloned()
}
fn output(s: String) -> *mut c_char {
    CString::new(s)
        .map(CString::into_raw)
        .unwrap_or(std::ptr::null_mut())
}

#[unsafe(no_mangle)]
pub extern "C" fn sq_core_abi_version() -> u32 {
    1
}

/// Input strings must be valid NUL-terminated UTF-8 for the duration of this call.
/// Returns zero on invalid configuration/panic. No foreign pointer is retained.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sq_core_open(endpoint: *const c_char, root: *const c_char) -> u64 {
    catch_unwind(AssertUnwindSafe(|| {
        if endpoint.is_null() || root.is_null() {
            return 0;
        }
        let Ok(endpoint) = (unsafe { CStr::from_ptr(endpoint) }).to_str() else {
            return 0;
        };
        let Ok(root) = (unsafe { CStr::from_ptr(root) }).to_str() else {
            return 0;
        };
        if endpoint.len() > 4096 || root.len() > 16384 {
            return 0;
        }
        let Ok(core) = Core::open(endpoint, PathBuf::from(root)) else {
            return 0;
        };
        let id = NEXT.fetch_add(1, Ordering::Relaxed);
        if let Ok(mut h) = handles().lock() {
            h.insert(id, Arc::new(core));
            id
        } else {
            0
        }
    }))
    .unwrap_or(0)
}

/// Blocking non-realtime call. Execute off UI/audio thread. Result is owned,
/// secret-bearing adapter JSON. Free exactly once using sq_core_string_free.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sq_core_execute(
    id: u64,
    epoch: u64,
    command: *const c_char,
) -> *mut c_char {
    catch_unwind(AssertUnwindSafe(|| {
        if command.is_null() {
            return output(r#"{"ok":false,"code":"invalid_input"}"#.into());
        }
        let raw = unsafe { CStr::from_ptr(command) };
        if raw.to_bytes().len() > 65536 {
            return output(r#"{"ok":false,"code":"input_too_large"}"#.into());
        }
        let Some(core) = get(id) else {
            return output(r#"{"ok":false,"code":"invalid_handle"}"#.into());
        };
        let Ok(command) = serde_json::from_slice::<Command>(raw.to_bytes()) else {
            return output(r#"{"ok":false,"code":"invalid_command"}"#.into());
        };
        output(
            serde_json::to_string(&core.execute_at(command, epoch))
                .unwrap_or_else(|_| r#"{"ok":false,"code":"serialization_failed"}"#.into()),
        )
    }))
    .unwrap_or_else(|_| output(r#"{"ok":false,"code":"core_failure"}"#.into()))
}

/// Synchronous nonblocking intent fence, independent of the command mutex.
#[unsafe(no_mangle)]
pub extern "C" fn sq_core_revoke(id: u64) -> u64 {
    catch_unwind(|| get(id).map(|c| c.revoke()).unwrap_or(0)).unwrap_or(0)
}

/// Remove admission and revoke outstanding calls. Arc retains ongoing work;
/// platform must stop/close its decoder before calling this function.
#[unsafe(no_mangle)]
pub extern "C" fn sq_core_close(id: u64) {
    let _ = catch_unwind(|| {
        if let Ok(mut handles) = handles().lock() {
            if let Some(core) = handles.remove(&id) {
                core.revoke();
            }
        }
    });
}

/// Only a non-null result from this same library, exactly once. No core lifetime
/// dependency: result ownership survives close. Other pointers are undefined.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sq_core_string_free(s: *mut c_char) {
    if !s.is_null() {
        drop(unsafe { CString::from_raw(s) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn invalid_handle_is_explicit() {
        let cmd = CString::new(r#"{"command":"snapshot"}"#).unwrap();
        let p = unsafe { sq_core_execute(u64::MAX, 1, cmd.as_ptr()) };
        let text = unsafe { CStr::from_ptr(p) }.to_str().unwrap();
        assert!(text.contains("invalid_handle"));
        unsafe { sq_core_string_free(p) };
    }
    #[test]
    fn version_is_fixed_width() {
        assert_eq!(sq_core_abi_version(), 1);
    }
}
