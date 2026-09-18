// Feasibility probe only; not an admitted Notebook content renderer.
// get_next checkpoints are deliberately incomplete: PDF/font/BibTeX work and
// whole-process memory limits are separate, still-open acceptance conditions.
use std::{
    ffi::{CStr, CString},
    fs::File,
    io::BufReader,
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc, Mutex, OnceLock,
    },
    time::{SystemTime, UNIX_EPOCH},
};
use tectonic::{
    driver::{OutputFormat, ProcessingSessionBuilder},
    status::NoopStatusBackend,
};
use tectonic_bundles::{zip::ZipBundle, Bundle};
use tectonic_io_base::{InputHandle, InputOrigin, IoProvider, OpenResult};
use tectonic_status_base::StatusBackend;
static RUN: Mutex<()> = Mutex::new(());
static BUNDLE: OnceLock<Mutex<Option<(PathBuf, Arc<Mutex<ZipBundle<File>>>)>>> = OnceLock::new();
struct SharedBundle(Arc<Mutex<ZipBundle<File>>>);
impl IoProvider for SharedBundle {
    fn input_open_name(
        &mut self,
        name: &str,
        status: &mut dyn StatusBackend,
    ) -> OpenResult<InputHandle> {
        self.0.lock().unwrap().input_open_name(name, status)
    }
}
impl Bundle for SharedBundle {
    fn all_files(&self) -> Vec<String> {
        self.0.lock().unwrap().all_files()
    }
    fn get_digest(&mut self) -> tectonic_errors::Result<tectonic_io_base::digest::DigestData> {
        self.0.lock().unwrap().get_digest()
    }
}
static INTERRUPTED: AtomicBool = AtomicBool::new(false);
static DEADLINE: AtomicU64 = AtomicU64::new(0);
fn nanos() -> u64 {
    unsafe {
        let mut value: libc::timespec = std::mem::zeroed();
        libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut value);
        value.tv_sec as u64 * 1_000_000_000 + value.tv_nsec as u64
    }
}
#[no_mangle]
pub extern "C" fn notebook_typeset_interrupted() -> libc::c_int {
    if INTERRUPTED.load(Ordering::Relaxed) {
        return 0;
    }
    if nanos() >= DEADLINE.load(Ordering::Relaxed) {
        INTERRUPTED.store(true, Ordering::Relaxed);
        return 1;
    }
    0
}
struct FontsOnly;
impl IoProvider for FontsOnly {
    fn input_open_name(
        &mut self,
        name: &str,
        _status: &mut dyn StatusBackend,
    ) -> OpenResult<InputHandle> {
        let path = Path::new(name);
        if !path.is_absolute() {
            return OpenResult::NotAvailable;
        }
        let path = match path.canonicalize() {
            Ok(p) => p,
            Err(_) => return OpenResult::NotAvailable,
        };
        if !path.starts_with("/System/Library/Fonts") {
            return OpenResult::NotAvailable;
        }
        if !matches!(
            path.extension().and_then(|e| e.to_str()),
            Some("ttf" | "ttc" | "otf" | "dfont")
        ) {
            return OpenResult::NotAvailable;
        }
        let file = match File::open(path) {
            Ok(f) => f,
            Err(e) => return OpenResult::Err(e.into()),
        };
        if file
            .metadata()
            .map(|m| m.len() > 32 * 1024 * 1024)
            .unwrap_or(true)
        {
            return OpenResult::NotAvailable;
        }
        OpenResult::Ok(InputHandle::new_read_only(
            name,
            BufReader::new(file),
            InputOrigin::Filesystem,
        ))
    }
}
pub fn compile(
    bundle: &Path,
    cache: &Path,
    source: &[u8],
    output: &Path,
    timeout_ms: u64,
) -> Result<String, String> {
    if source.len() > 4 * 1024 * 1024 {
        return Err("source exceeds 4 MiB".into());
    }
    let _serial = RUN.lock().map_err(|e| e.to_string())?;
    INTERRUPTED.store(false, Ordering::Relaxed);
    DEADLINE.store(
        nanos().saturating_add(timeout_ms.saturating_mul(1_000_000)),
        Ordering::Relaxed,
    );
    let started = std::time::Instant::now();
    let result = (|| -> Result<String, Box<dyn std::error::Error>> {
        let mut status = NoopStatusBackend::default();
        let mut cached = BUNDLE.get_or_init(|| Mutex::new(None)).lock().unwrap();
        if cached.as_ref().map(|(p, _)| p.as_path()) != Some(bundle) {
            *cached = Some((
                bundle.to_owned(),
                Arc::new(Mutex::new(ZipBundle::open(bundle)?)),
            ));
        }
        let bundle = SharedBundle(Arc::clone(&cached.as_ref().unwrap().1));
        drop(cached);
        let mut builder = ProcessingSessionBuilder::default();
        builder
            .primary_input_buffer(source)
            .tex_input_name("document.tex")
            .format_name("latex")
            .format_cache_path(cache)
            .bundle(Box::new(bundle))
            .input_provider(Box::new(FontsOnly))
            .do_not_write_output_files()
            .output_format(OutputFormat::Pdf)
            .keep_intermediates(true)
            .keep_logs(true)
            .synctex(true)
            .build_date(SystemTime::from(UNIX_EPOCH))
            .shell_escape_disabled();
        let mut session = builder.create(&mut status)?;
        if let Err(e) = session.run(&mut status) {
            let stdout = String::from_utf8_lossy(&session.get_stdout_content()).into_owned();
            return Err(format!(
                "{e}\n{}",
                stdout
                    .chars()
                    .rev()
                    .take(1600)
                    .collect::<String>()
                    .chars()
                    .rev()
                    .collect::<String>()
            )
            .into());
        }
        let files = session.into_file_data();
        let pdf = files.get("document.pdf").ok_or("no PDF")?;
        std::fs::write(output, &pdf.data)?;
        if let Some(map) = files.get("document.synctex.gz") {
            std::fs::write(output.with_extension("synctex.gz"), &map.data)?;
        }
        Ok(format!(
            "OK elapsed_ms={} pdf_bytes={} files={:?}",
            started.elapsed().as_millis(),
            pdf.data.len(),
            files.keys().collect::<Vec<_>>()
        ))
    })()
    .map_err(|e| e.to_string());
    result
}
#[no_mangle]
pub unsafe extern "C" fn notebook_typeset_compile(
    bundle: *const libc::c_char,
    cache: *const libc::c_char,
    source: *const libc::c_char,
    output: *const libc::c_char,
    timeout_ms: u64,
) -> *mut libc::c_char {
    let result = std::panic::catch_unwind(|| {
        let bundle = PathBuf::from(CStr::from_ptr(bundle).to_string_lossy().into_owned());
        let cache = PathBuf::from(CStr::from_ptr(cache).to_string_lossy().into_owned());
        let output = PathBuf::from(CStr::from_ptr(output).to_string_lossy().into_owned());
        compile(
            &bundle,
            &cache,
            CStr::from_ptr(source).to_bytes(),
            &output,
            timeout_ms,
        )
        .unwrap_or_else(|e| format!("ERROR {e}"))
    })
    .unwrap_or_else(|_| "ERROR engine panic".into());
    CString::new(result.replace('\0', " ")).unwrap().into_raw()
}
#[no_mangle]
pub unsafe extern "C" fn notebook_typeset_free(message: *mut libc::c_char) {
    if !message.is_null() {
        drop(CString::from_raw(message));
    }
}
