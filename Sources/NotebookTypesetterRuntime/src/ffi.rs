use super::{Output, Runtime};
use std::{ffi::{CStr, c_char}, path::Path, sync::atomic::{AtomicBool, Ordering}, time::Duration};
#[repr(C)]
pub struct Asset { name: *const c_char, bytes: *const u8, count: usize }
pub struct ResultHandle(Result<Output, String>);
unsafe fn string<'a>(p: *const c_char) -> Result<&'a str, String> {
    if p.is_null() { return Err("typesetter_argument".into()); }
    unsafe { CStr::from_ptr(p) }.to_str().map_err(|_| "typesetter_encoding".into())
}
fn resource(path: &str, limit: u64) -> Result<Vec<u8>, String> {
    let file = std::fs::File::open(path).map_err(|e| e.to_string())?;
    if file.metadata().map_err(|e| e.to_string())?.len() > limit { return Err("typesetter_resource_limit".into()); }
    use std::io::Read;
    let mut bytes = Vec::new(); file.take(limit + 1).read_to_end(&mut bytes).map_err(|e| e.to_string())?;
    if bytes.len() as u64 > limit { return Err("typesetter_resource_limit".into()); }
    Ok(bytes)
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nb_typesetter_create(bundle: *const c_char, format: *const c_char, fonts: *const c_char) -> *mut Runtime {
    let create = || unsafe { Runtime::new(Path::new(string(bundle)?), resource(string(format)?, 32*1024*1024)?, resource(string(fonts)?, 2*1024*1024)?) };
    create().map(|v| Box::into_raw(Box::new(v))).unwrap_or(std::ptr::null_mut())
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nb_typesetter_destroy(p: *mut Runtime) { if !p.is_null() { drop(unsafe { Box::from_raw(p) }); } }
#[unsafe(no_mangle)]
pub extern "C" fn nb_typesetter_cancel_create() -> *mut AtomicBool { Box::into_raw(Box::new(AtomicBool::new(false))) }
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nb_typesetter_cancel(p: *mut AtomicBool) { if !p.is_null() { unsafe { &*p }.store(true, Ordering::Relaxed); } }
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nb_typesetter_cancel_destroy(p: *mut AtomicBool) { if !p.is_null() { drop(unsafe { Box::from_raw(p) }); } }
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nb_typesetter_compile(runtime: *const Runtime, bytes: *const u8, count: usize,
    assets: *const Asset, asset_count: usize, epoch: u64, timeout_ms: u64, cancel: *const AtomicBool) -> *mut ResultHandle {
    let compile = || {
        if runtime.is_null() || bytes.is_null() || cancel.is_null() || count > 4*1024*1024 || asset_count > 128 || (asset_count > 0 && assets.is_null()) {
            return Err("typesetter_input_limit".into());
        }
        let source = std::str::from_utf8(unsafe { std::slice::from_raw_parts(bytes, count) }).map_err(|_| "typesetter_encoding".to_string())?;
        let list = if asset_count == 0 { &[] } else { unsafe { std::slice::from_raw_parts(assets, asset_count) } };
        let total = list.iter().try_fold(0usize, |n, a| n.checked_add(a.count)).ok_or("typesetter_input_limit")?;
        if total > 16*1024*1024 { return Err("typesetter_input_limit".into()); }
        let mut owned = Vec::with_capacity(list.len());
        for asset in list {
            if asset.bytes.is_null() { return Err("typesetter_argument".into()); }
            let name = unsafe { string(asset.name)? };
            if name.len() > 256 { return Err("typesetter_input_limit".into()); }
            owned.push((name.into(), unsafe { std::slice::from_raw_parts(asset.bytes, asset.count) }.to_vec()));
        }
        unsafe { &*runtime }.compile(source, owned, epoch, Duration::from_millis(timeout_ms.min(30_000)), unsafe { &*cancel })
    };
    Box::into_raw(Box::new(ResultHandle(compile())))
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nb_typesetter_output_bytes(p: *const ResultHandle, kind: u32, count: *mut usize) -> *const u8 {
    let value: &[u8] = match (&unsafe { &*p }.0, kind) {
        (Ok(v), 0) => &v.pdf, (Ok(v), 1) => &v.synctex, (Ok(v), 2) => v.log.as_bytes(), (Err(e), 3) => e.as_bytes(), _ => &[],
    };
    unsafe { *count = value.len(); } value.as_ptr()
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nb_typesetter_output_memory(p: *const ResultHandle) -> usize { unsafe { &*p }.0.as_ref().map(|v| v.memory_bytes).unwrap_or(0) }
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nb_typesetter_output_destroy(p: *mut ResultHandle) { if !p.is_null() { drop(unsafe { Box::from_raw(p) }); } }

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nb_typesetter_svg(runtime: *const Runtime, bytes: *const u8, count: usize,
    timeout_ms: u64, cancel: *const AtomicBool) -> *mut ResultHandle {
    let result = (|| {
        if runtime.is_null() || bytes.is_null() || cancel.is_null() || count > 8*1024*1024 { return Err("typesetter_input_limit".into()); }
        let source = std::str::from_utf8(unsafe { std::slice::from_raw_parts(bytes, count) }).map_err(|_| "typesetter_encoding".to_string())?;
        unsafe { &*runtime }.convert_svg(source, Duration::from_millis(timeout_ms.min(30_000)), unsafe { &*cancel })
    })();
    Box::into_raw(Box::new(ResultHandle(result)))
}
