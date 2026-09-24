//! Capability-only WASI filesystem. No guest path reaches an OS filesystem.
//! ZIP entries, inputs and outputs share a hard byte/handle budget, released
//! with their actual buffers. A seek does not allocate and a sparse write is
//! charged before resizing. Logs are a bounded tail, not an unbounded pipe.
use std::{any::Any, collections::BTreeMap, fs::File, io::{self, Read, SeekFrom, Write}, path::{Path, PathBuf}, sync::{Arc, Mutex, OnceLock, atomic::{AtomicUsize, Ordering}}};
use wasi_common::{Error, ErrorExt, WasiDir, WasiFile, dir::{OpenResult, ReaddirCursor, ReaddirEntity}, file::{FdFlags, FileType, Filestat, OFlags}};

const MAX_FILE: usize = 32 * 1024 * 1024;
const MAX_FILES: usize = 64 * 1024 * 1024;
const MAX_HANDLES: usize = 128;
#[derive(Default)]
pub struct Budget { bytes: AtomicUsize, handles: AtomicUsize, resource_failure: Mutex<Option<String>> }
impl Budget {
    fn resource_error(&self, error: impl std::fmt::Display) -> Error {
        let mut failure = self.resource_failure.lock().unwrap();
        if failure.is_none() { *failure = Some(format!("typesetter_resources_unavailable: {error}")); }
        Error::io()
    }
    pub fn resource_failure(&self) -> Option<String> { self.resource_failure.lock().unwrap().clone() }
    fn acquire(counter: &AtomicUsize, count: usize, limit: usize) -> Result<(), Error> {
        counter.fetch_update(Ordering::Relaxed, Ordering::Relaxed, |old| old.checked_add(count).filter(|n| *n <= limit))
            .map(|_| ()).map_err(|_| Error::io())
    }
}
struct Buffer { bytes: Vec<u8>, budget: Arc<Budget> }
impl Buffer {
    fn new(bytes: Vec<u8>, budget: &Arc<Budget>) -> Result<Self, Error> {
        if bytes.len() > MAX_FILE { return Err(Error::io()); }
        Budget::acquire(&budget.bytes, bytes.len(), MAX_FILES)?;
        Ok(Self { bytes, budget: budget.clone() })
    }
    fn resize(&mut self, len: usize) -> Result<(), Error> {
        if len > MAX_FILE { return Err(Error::io()); }
        let old = self.bytes.len();
        if len > old {
            Budget::acquire(&self.budget.bytes, len - old, MAX_FILES)?;
            if self.bytes.try_reserve_exact(len - old).is_err() {
                self.budget.bytes.fetch_sub(len - old, Ordering::Relaxed); return Err(Error::io());
            }
        } else { self.budget.bytes.fetch_sub(old - len, Ordering::Relaxed); }
        self.bytes.resize(len, 0); if len < old { self.bytes.shrink_to_fit(); } Ok(())
    }
}
impl Drop for Buffer { fn drop(&mut self) { self.budget.bytes.fetch_sub(self.bytes.len(), Ordering::Relaxed); } }
type SharedBuffer = Arc<Mutex<Buffer>>;
struct Handle { buffer: SharedBuffer, position: Mutex<u64>, writable: bool, budget: Arc<Budget> }
impl Handle {
    fn new(buffer: SharedBuffer, writable: bool, budget: &Arc<Budget>) -> Result<Self, Error> {
        Budget::acquire(&budget.handles, 1, MAX_HANDLES)?;
        Ok(Self { buffer, position: Mutex::new(0), writable, budget: budget.clone() })
    }
    fn read(&self, bufs: &mut [io::IoSliceMut<'_>], pos: &mut u64) -> Result<u64, Error> {
        let file = self.buffer.lock().unwrap(); let start = *pos;
        for buf in bufs {
            let at = usize::try_from(*pos).unwrap_or(usize::MAX).min(file.bytes.len());
            let count = buf.len().min(file.bytes.len() - at);
            buf[..count].copy_from_slice(&file.bytes[at..at+count]); *pos += count as u64;
            if count < buf.len() { break; }
        }
        Ok(*pos - start)
    }
    fn write(&self, bufs: &[io::IoSlice<'_>], pos: &mut u64) -> Result<u64, Error> {
        if !self.writable { return Err(Error::badf()); }
        let count = bufs.iter().try_fold(0usize, |n, b| n.checked_add(b.len())).ok_or_else(Error::io)?;
        let start = usize::try_from(*pos).map_err(|_| Error::io())?;
        let end = start.checked_add(count).filter(|n| *n <= MAX_FILE).ok_or_else(Error::io)?;
        let mut file = self.buffer.lock().unwrap();
        if end > file.bytes.len() { file.resize(end)?; }
        let mut at = start;
        for buf in bufs { file.bytes[at..at+buf.len()].copy_from_slice(buf); at += buf.len(); }
        *pos = end as u64; Ok(count as u64)
    }
}
impl Drop for Handle { fn drop(&mut self) { self.budget.handles.fetch_sub(1, Ordering::Relaxed); } }
fn stat(kind: FileType, size: u64) -> Filestat { Filestat { device_id: 1, inode: 1, filetype: kind, nlink: 1, size, atim: None, mtim: None, ctim: None } }
#[wiggle::async_trait]
impl WasiFile for Handle {
    fn as_any(&self) -> &dyn Any { self }
    async fn get_filetype(&self) -> Result<FileType, Error> { Ok(FileType::RegularFile) }
    async fn get_filestat(&self) -> Result<Filestat, Error> { Ok(stat(FileType::RegularFile, self.buffer.lock().unwrap().bytes.len() as u64)) }
    async fn read_vectored<'a>(&self, b: &mut [io::IoSliceMut<'a>]) -> Result<u64, Error> { self.read(b, &mut self.position.lock().unwrap()) }
    async fn read_vectored_at<'a>(&self, b: &mut [io::IoSliceMut<'a>], mut offset: u64) -> Result<u64, Error> { self.read(b, &mut offset) }
    async fn write_vectored<'a>(&self, b: &[io::IoSlice<'a>]) -> Result<u64, Error> { self.write(b, &mut self.position.lock().unwrap()) }
    async fn write_vectored_at<'a>(&self, b: &[io::IoSlice<'a>], mut offset: u64) -> Result<u64, Error> { self.write(b, &mut offset) }
    async fn seek(&self, from: SeekFrom) -> Result<u64, Error> {
        let mut pos = self.position.lock().unwrap();
        let next = match from { SeekFrom::Start(p) => i128::from(p), SeekFrom::Current(d) => i128::from(*pos)+i128::from(d), SeekFrom::End(d) => self.buffer.lock().unwrap().bytes.len() as i128+i128::from(d) };
        *pos = u64::try_from(next).map_err(|_| Error::invalid_argument())?; Ok(*pos)
    }
    async fn set_filestat_size(&self, size: u64) -> Result<(), Error> {
        if !self.writable { return Err(Error::badf()); }
        self.buffer.lock().unwrap().resize(usize::try_from(size).map_err(|_| Error::io())?)
    }
    async fn set_fdflags(&mut self, flags: FdFlags) -> Result<(), Error> { if flags.is_empty() { Ok(()) } else { Err(Error::not_supported()) } }
}

/// Pinned resources are read only when the guest actually needs them. A path
/// drawing needs neither the TeX format nor the 134k-entry distribution index.
pub struct ResourceFile {
    path: PathBuf,
    limit: u64,
    bytes: OnceLock<Result<Vec<u8>, String>>,
}
impl ResourceFile {
    pub fn new(path: &Path, limit: u64) -> Self { Self { path: path.into(), limit, bytes: OnceLock::new() } }
    pub fn bytes(&self) -> Result<Vec<u8>, String> {
        self.bytes.get_or_init(|| {
            let file = File::open(&self.path).map_err(|e| e.to_string())?;
            if file.metadata().map_err(|e| e.to_string())?.len() > self.limit { return Err("typesetter_resource_limit".into()); }
            let mut bytes = Vec::new();
            file.take(self.limit + 1).read_to_end(&mut bytes).map_err(|e| e.to_string())?;
            if bytes.len() as u64 > self.limit { return Err("typesetter_resource_limit".into()); }
            Ok(bytes)
        }).clone()
    }
}

pub struct Bundle {
    path: PathBuf,
    archive: Mutex<Option<zip::ZipArchive<File>>>,
    names: [OnceLock<Arc<Vec<String>>>; 2],
}
impl Bundle {
    pub fn new(path: &Path) -> Self { Self { path: path.into(), archive: Mutex::new(None), names: Default::default() } }
    fn with_archive<T>(&self, budget: &Budget, read: impl FnOnce(&mut zip::ZipArchive<File>) -> Result<T, Error>) -> Result<T, Error> {
        let mut slot = self.archive.lock().unwrap();
        if slot.is_none() {
            let file = File::open(&self.path).map_err(|error| budget.resource_error(error))?;
            let archive = zip::ZipArchive::new(file).map_err(|error| budget.resource_error(error))?;
            // The native resource owner verifies the immutable distribution.
            if archive.len() > 150_000 { return Err(budget.resource_error("TeX distribution entry limit")); }
            *slot = Some(archive);
        }
        read(slot.as_mut().unwrap())
    }
    fn names(&self, fonts_only: bool, budget: &Budget) -> Result<Arc<Vec<String>>, Error> {
        let slot = &self.names[usize::from(fonts_only)];
        if let Some(names) = slot.get() { return Ok(names.clone()); }
        let names = self.with_archive(budget, |archive| Ok(Arc::new(archive.file_names()
            .filter(|name| !fonts_only || name.ends_with(".otf") || name.ends_with(".ttf"))
            .map(String::from).collect())))?;
        Ok(slot.get_or_init(|| names).clone())
    }
    fn size(&self, name: &str, budget: &Budget) -> Result<u64, Error> {
        self.with_archive(budget, |archive| archive.by_name(name).map(|f| f.size()).map_err(|_| Error::not_found()))
    }
    fn read(&self, name: &str, budget: &Arc<Budget>) -> Result<SharedBuffer, Error> {
        self.with_archive(budget, |zip| {
            let mut file = zip.by_name(name).map_err(|_| Error::not_found())?;
            let size = usize::try_from(file.size()).map_err(|_| Error::io())?;
            if size > MAX_FILE { return Err(Error::io()); }
            // Charge before decompression; a lazy index does not relax bounds.
            let mut data = Buffer::new(Vec::new(), budget)?; data.resize(size)?;
            file.read_exact(&mut data.bytes).map_err(|error| budget.resource_error(error))?;
            Ok(Arc::new(Mutex::new(data)))
        })
    }
}
#[derive(Clone)]
pub struct Directory {
    files: Arc<Mutex<BTreeMap<String, SharedBuffer>>>,
    bundle: Option<Arc<Bundle>>, fonts_only: bool, writable: bool, budget: Arc<Budget>,
}
impl Directory {
    pub fn new(writable: bool, budget: &Arc<Budget>) -> Self { Self { files: Default::default(), bundle: None, fonts_only: false, writable, budget: budget.clone() } }
    pub fn bundle(bundle: Arc<Bundle>, fonts_only: bool, budget: &Arc<Budget>) -> Self {
        Self { bundle: Some(bundle), fonts_only, ..Self::new(false, budget) }
    }
    pub fn put(&self, name: &str, bytes: Vec<u8>) -> Result<(), Error> {
        Self::name(name)?;
        let mut files = self.files.lock().unwrap();
        if files.len() >= MAX_HANDLES && !files.contains_key(name) { return Err(Error::io()); }
        files.insert(name.into(), Arc::new(Mutex::new(Buffer::new(bytes, &self.budget)?))); Ok(())
    }
    pub fn take(&self, name: &str) -> Option<Vec<u8>> {
        let shared = self.files.lock().unwrap().remove(name)?;
        let mut buffer = shared.lock().unwrap(); let bytes = std::mem::take(&mut buffer.bytes);
        buffer.budget.bytes.fetch_sub(bytes.len(), Ordering::Relaxed); Some(bytes)
    }
    fn name(name: &str) -> Result<&str, Error> {
        let name = name.strip_prefix("./").unwrap_or(name);
        if name.is_empty() || name.len() > 256 || name.contains('/') || name.contains('\\') || name == "." || name == ".." || name.contains('\0') { return Err(Error::not_found()); }
        Ok(name)
    }
}
#[wiggle::async_trait]
impl WasiDir for Directory {
    fn as_any(&self) -> &dyn Any { self }
    async fn get_filestat(&self) -> Result<Filestat, Error> { Ok(stat(FileType::Directory, 0)) }
    async fn get_path_filestat(&self, name: &str, _: bool) -> Result<Filestat, Error> {
        if name == "." || name.is_empty() { return self.get_filestat().await; }
        let name = Self::name(name)?;
        if let Some(file) = self.files.lock().unwrap().get(name) { return Ok(stat(FileType::RegularFile, file.lock().unwrap().bytes.len() as u64)); }
        Ok(stat(FileType::RegularFile, self.bundle.as_ref().ok_or_else(Error::not_found)?.size(name, &self.budget)?))
    }
    async fn open_file(&self, _: bool, name: &str, flags: OFlags, _: bool, write: bool, fd: FdFlags) -> Result<OpenResult, Error> {
        if name == "." || name.is_empty() { return Ok(OpenResult::Dir(Box::new(self.clone()))); }
        let name = Self::name(name)?;
        if (write || flags.intersects(OFlags::CREATE | OFlags::TRUNCATE)) && !self.writable { return Err(Error::not_supported()); }
        if flags.contains(OFlags::DIRECTORY) || !fd.is_empty() { return Err(Error::not_supported()); }
        let mut files = self.files.lock().unwrap();
        let buffer = if let Some(file) = files.get(name) {
            if flags.contains(OFlags::EXCLUSIVE) { return Err(Error::exist()); }
            if flags.contains(OFlags::TRUNCATE) { file.lock().unwrap().resize(0)?; }
            file.clone()
        } else if self.writable && flags.contains(OFlags::CREATE) {
            if files.len() >= MAX_HANDLES { return Err(Error::io()); }
            let file = Arc::new(Mutex::new(Buffer::new(Vec::new(), &self.budget)?)); files.insert(name.into(), file.clone()); file
        } else { self.bundle.as_ref().ok_or_else(Error::not_found)?.read(name, &self.budget)? };
        Ok(OpenResult::File(Box::new(Handle::new(buffer, write, &self.budget)?)))
    }
    async fn readdir(&self, cursor: ReaddirCursor) -> Result<Box<dyn Iterator<Item=Result<ReaddirEntity, Error>> + Send>, Error> {
        let at = u64::from(cursor) as usize;
        let names = if let Some(bundle) = &self.bundle { bundle.names(self.fonts_only, &self.budget)? }
            else { Arc::new(self.files.lock().unwrap().keys().cloned().collect()) };
        Ok(Box::new((at..names.len()).map(move |i| Ok(ReaddirEntity { next: ((i+1) as u64).into(), inode: (i+1) as u64, name: names[i].clone(), filetype: FileType::RegularFile }))))
    }
    async fn create_dir(&self, name: &str) -> Result<(), Error> { if name == "." || name.is_empty() { Ok(()) } else { Err(Error::not_supported()) } }
}

#[derive(Clone, Default)]
pub struct Log(pub Arc<Mutex<Vec<u8>>>);
impl Write for Log {
    fn write(&mut self, data: &[u8]) -> io::Result<usize> {
        let mut tail = self.0.lock().unwrap(); const LIMIT: usize = 64*1024;
        let appended = &data[data.len().saturating_sub(LIMIT)..];
        let discard = (tail.len()+appended.len()).saturating_sub(LIMIT); tail.drain(..discard); tail.extend_from_slice(appended);
        Ok(data.len())
    }
    fn flush(&mut self) -> io::Result<()> { Ok(()) }
}
