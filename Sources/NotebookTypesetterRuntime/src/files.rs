//! Capability-only WASI filesystem. No guest path reaches an OS filesystem.
//! ZIP entries, inputs and outputs share a hard byte/handle budget, released
//! with their actual buffers. A seek does not allocate and a sparse write is
//! charged before resizing. Logs are a bounded tail, not an unbounded pipe.
use std::{any::Any, collections::{BTreeMap, VecDeque}, fs::File, io::{self, Read, SeekFrom, Write}, path::{Path, PathBuf}, sync::{Arc, Mutex, OnceLock, Weak, atomic::{AtomicUsize, Ordering}}};
use wasi_common::{Error, ErrorExt, WasiDir, WasiFile, dir::{OpenResult, ReaddirCursor, ReaddirEntity}, file::{FdFlags, FileType, Filestat, OFlags}};

const MAX_FILE: usize = 32 * 1024 * 1024;
const MAX_FILES: usize = 64 * 1024 * 1024;
const MAX_HANDLES: usize = 128;
const MAX_ENTRIES: usize = 4096;
#[derive(Default)]
pub struct Budget {
    bytes: AtomicUsize, handles: AtomicUsize, resource_failure: Mutex<Option<String>>,
    inflated: Mutex<Weak<ResourceCache>>,
}
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
    fn acquire_bytes(&self, count: usize) -> Result<(), Error> {
        if Self::acquire(&self.bytes, count, MAX_FILES).is_ok() { return Ok(()); }
        // Optional reuse must never prevent an allocation which fitted before
        // caching. Open handles pin their bytes; idle archive entries do not.
        if let Some(cache) = self.inflated.lock().unwrap().upgrade() {
            cache.release_unused(self, count);
        }
        Self::acquire(&self.bytes, count, MAX_FILES)
    }
}
enum BufferBytes { Owned(Vec<u8>), Pinned(Arc<Vec<u8>>) }
impl BufferBytes {
    fn data(&self) -> &[u8] { match self { Self::Owned(bytes) => bytes.as_slice(), Self::Pinned(bytes) => bytes.as_slice() } }
    fn owned(&mut self) -> Result<&mut Vec<u8>, Error> {
        match self { Self::Owned(bytes) => Ok(bytes), Self::Pinned(_) => Err(Error::badf()) }
    }
}
struct Buffer { bytes: BufferBytes, budget: Arc<Budget> }
impl Buffer {
    fn new(bytes: Vec<u8>, budget: &Arc<Budget>) -> Result<Self, Error> {
        Self::admit(BufferBytes::Owned(bytes), budget)
    }
    fn admit(bytes: BufferBytes, budget: &Arc<Budget>) -> Result<Self, Error> {
        let bytes_len = bytes.data().len();
        if bytes_len > MAX_FILE { return Err(Error::io()); }
        budget.acquire_bytes(bytes_len)?;
        Ok(Self { bytes, budget: budget.clone() })
    }
    fn resize(&mut self, len: usize) -> Result<(), Error> {
        if len > MAX_FILE { return Err(Error::io()); }
        let bytes = self.bytes.owned()?;
        let old = bytes.len();
        if len > old {
            self.budget.acquire_bytes(len - old)?;
            if bytes.try_reserve_exact(len - old).is_err() {
                self.budget.bytes.fetch_sub(len - old, Ordering::Relaxed); return Err(Error::io());
            }
        } else { self.budget.bytes.fetch_sub(old - len, Ordering::Relaxed); }
        bytes.resize(len, 0); if len < old { bytes.shrink_to_fit(); } Ok(())
    }
}
impl Drop for Buffer { fn drop(&mut self) { self.budget.bytes.fetch_sub(self.bytes.data().len(), Ordering::Relaxed); } }
type SharedBuffer = Arc<Mutex<Buffer>>;

/// The two immutable resource mounts share only bytes read in this compile.
/// Entries remain charged to its existing 64 MiB budget and can be reclaimed
/// before any input/output allocation. Nothing survives the physical run.
pub struct ResourceCache { entries: Mutex<VecDeque<(String, usize, SharedBuffer)>> }
impl ResourceCache {
    pub fn new(budget: &Arc<Budget>) -> Arc<Self> {
        let cache = Arc::new(Self { entries: Mutex::new(VecDeque::new()) });
        *budget.inflated.lock().unwrap() = Arc::downgrade(&cache);
        cache
    }
    fn get(&self, name: &str) -> Option<SharedBuffer> {
        let mut entries = self.entries.lock().unwrap();
        let index = entries.iter().position(|(path, _, _)| path == name)?;
        let entry = entries.remove(index).unwrap();
        let value = entry.2.clone(); entries.push_back(entry); Some(value)
    }
    fn insert(&self, name: &str, buffer: &SharedBuffer) {
        const MAX_REUSED_BYTES: usize = 8 * 1024 * 1024;
        let bytes = buffer.lock().unwrap().bytes.data().len();
        if bytes > MAX_REUSED_BYTES { return; }
        let mut entries = self.entries.lock().unwrap();
        entries.retain(|(path, _, _)| path != name);
        let mut retained = entries.iter().map(|(_, bytes, _)| *bytes).sum::<usize>();
        while retained + bytes > MAX_REUSED_BYTES || entries.len() >= 256 {
            let Some((_, bytes, _)) = entries.pop_front() else { break };
            retained -= bytes;
        }
        entries.push_back((name.into(), bytes, buffer.clone()));
    }
    fn release_unused(&self, budget: &Budget, count: usize) {
        let mut entries = self.entries.lock().unwrap();
        let mut index = 0;
        while budget.bytes.load(Ordering::Relaxed).checked_add(count).is_none_or(|n| n > MAX_FILES)
            && index < entries.len() {
            if Arc::strong_count(&entries[index].2) == 1 { entries.remove(index); }
            else { index += 1; }
        }
    }
}
struct Handle { buffer: SharedBuffer, position: Mutex<u64>, writable: bool, budget: Arc<Budget> }
impl Handle {
    fn new(buffer: SharedBuffer, writable: bool, budget: &Arc<Budget>) -> Result<Self, Error> {
        Budget::acquire(&budget.handles, 1, MAX_HANDLES)?;
        Ok(Self { buffer, position: Mutex::new(0), writable, budget: budget.clone() })
    }
    fn read(&self, bufs: &mut [io::IoSliceMut<'_>], pos: &mut u64) -> Result<u64, Error> {
        let file = self.buffer.lock().unwrap(); let start = *pos;
        for buf in bufs {
            let bytes = file.bytes.data();
            let at = usize::try_from(*pos).unwrap_or(usize::MAX).min(bytes.len());
            let count = buf.len().min(bytes.len() - at);
            buf[..count].copy_from_slice(&bytes[at..at+count]); *pos += count as u64;
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
        if end > file.bytes.data().len() { file.resize(end)?; }
        let bytes = file.bytes.owned()?;
        let mut at = start;
        for buf in bufs { bytes[at..at+buf.len()].copy_from_slice(buf); at += buf.len(); }
        *pos = end as u64; Ok(count as u64)
    }
}
impl Drop for Handle { fn drop(&mut self) { self.budget.handles.fetch_sub(1, Ordering::Relaxed); } }
fn stat(kind: FileType, size: u64) -> Filestat { Filestat { device_id: 1, inode: 1, filetype: kind, nlink: 1, size, atim: None, mtim: None, ctim: None } }
#[wiggle::async_trait]
impl WasiFile for Handle {
    fn as_any(&self) -> &dyn Any { self }
    async fn get_filetype(&self) -> Result<FileType, Error> { Ok(FileType::RegularFile) }
    async fn get_filestat(&self) -> Result<Filestat, Error> { Ok(stat(FileType::RegularFile, self.buffer.lock().unwrap().bytes.data().len() as u64)) }
    async fn read_vectored<'a>(&self, b: &mut [io::IoSliceMut<'a>]) -> Result<u64, Error> { self.read(b, &mut self.position.lock().unwrap()) }
    async fn read_vectored_at<'a>(&self, b: &mut [io::IoSliceMut<'a>], mut offset: u64) -> Result<u64, Error> { self.read(b, &mut offset) }
    async fn write_vectored<'a>(&self, b: &[io::IoSlice<'a>]) -> Result<u64, Error> { self.write(b, &mut self.position.lock().unwrap()) }
    async fn write_vectored_at<'a>(&self, b: &[io::IoSlice<'a>], mut offset: u64) -> Result<u64, Error> { self.write(b, &mut offset) }
    async fn seek(&self, from: SeekFrom) -> Result<u64, Error> {
        let mut pos = self.position.lock().unwrap();
        let next = match from { SeekFrom::Start(p) => i128::from(p), SeekFrom::Current(d) => i128::from(*pos)+i128::from(d), SeekFrom::End(d) => self.buffer.lock().unwrap().bytes.data().len() as i128+i128::from(d) };
        *pos = u64::try_from(next).map_err(|_| Error::invalid_argument())?; Ok(*pos)
    }
    async fn set_filestat_size(&self, size: u64) -> Result<(), Error> {
        if !self.writable { return Err(Error::badf()); }
        self.buffer.lock().unwrap().resize(usize::try_from(size).map_err(|_| Error::io())?)
    }
    async fn set_fdflags(&mut self, flags: FdFlags) -> Result<(), Error> { if flags.is_empty() { Ok(()) } else { Err(Error::not_supported()) } }
}

/// Pinned resources are read only when the guest actually needs them. Their
/// immutable bytes belong to Runtime; each compile borrows and charges them
/// without cloning the format. A path drawing does not load the TeX format.
pub struct ResourceFile {
    path: PathBuf,
    limit: u64,
    bytes: OnceLock<Result<Arc<Vec<u8>>, String>>,
}
impl ResourceFile {
    pub fn new(path: &Path, limit: u64) -> Self { Self { path: path.into(), limit, bytes: OnceLock::new() } }
    pub fn bytes(&self) -> Result<Arc<Vec<u8>>, String> {
        self.bytes.get_or_init(|| {
            let file = File::open(&self.path).map_err(|e| e.to_string())?;
            if file.metadata().map_err(|e| e.to_string())?.len() > self.limit { return Err("typesetter_resource_limit".into()); }
            let mut bytes = Vec::new();
            file.take(self.limit + 1).read_to_end(&mut bytes).map_err(|e| e.to_string())?;
            if bytes.len() as u64 > self.limit { return Err("typesetter_resource_limit".into()); }
            Ok(Arc::new(bytes))
        }).clone()
    }
}

// One cursor and bounded read-ahead buffer for the immutable distribution.
// Zip's position queries and absolute no-op seeks must not discard read-ahead.
const ZIP_READER_BUFFER_BYTES: usize = 8 * 1024;
struct BundleReader {
    file: io::BufReader<File>,
    position: u64,
}
impl BundleReader {
    fn new(mut file: File) -> io::Result<Self> {
        let position = std::io::Seek::stream_position(&mut file)?;
        Ok(Self { file: io::BufReader::with_capacity(ZIP_READER_BUFFER_BYTES, file), position })
    }
}
impl Read for BundleReader {
    fn read(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
        let count = self.file.read(bytes)?;
        self.position = self.position.checked_add(count as u64)
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "archive position overflow"))?;
        Ok(count)
    }
}
impl std::io::Seek for BundleReader {
    fn seek(&mut self, from: SeekFrom) -> io::Result<u64> {
        let target = match from {
            SeekFrom::Start(position) => Some(position),
            SeekFrom::Current(delta) => u64::try_from(i128::from(self.position) + i128::from(delta)).ok(),
            SeekFrom::End(_) => None,
        };
        if let Some(target) = target {
            if let Ok(delta) = i64::try_from(i128::from(target) - i128::from(self.position)) {
                self.file.seek_relative(delta)?;
                self.position = target;
                return Ok(target);
            }
        }
        self.position = self.file.seek(from)?;
        Ok(self.position)
    }
    fn stream_position(&mut self) -> io::Result<u64> { Ok(self.position) }
}

pub struct Bundle {
    path: PathBuf,
    archive: Mutex<Option<zip::ZipArchive<BundleReader>>>,
    names: [OnceLock<Arc<Vec<String>>>; 2],
}
impl Bundle {
    pub fn new(path: &Path) -> Self { Self { path: path.into(), archive: Mutex::new(None), names: Default::default() } }
    fn with_archive<T>(&self, budget: &Budget, read: impl FnOnce(&mut zip::ZipArchive<BundleReader>) -> Result<T, Error>) -> Result<T, Error> {
        let mut slot = self.archive.lock().unwrap();
        if slot.is_none() {
            let file = File::open(&self.path).map_err(|error| budget.resource_error(error))?;
            let reader = BundleReader::new(file).map_err(|error| budget.resource_error(error))?;
            let archive = zip::ZipArchive::new(reader).map_err(|error| budget.resource_error(error))?;
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
            file.read_exact(data.bytes.owned()?).map_err(|error| budget.resource_error(error))?;
            // Zip validates CRC at EOF, not after an exact-sized read. One
            // bounded probe also rejects a false uncompressed-size header.
            let mut end = [0];
            if file.read(&mut end).map_err(|error| budget.resource_error(error))? != 0 {
                return Err(budget.resource_error("TeX resource size differs"));
            }
            Ok(Arc::new(Mutex::new(data)))
        })
    }
}
/// Every lookup of the immutable input namespace is a rendering dependency,
/// including failed probes and directory enumeration. Bundle lookups belong to
/// the pinned compiler recipe and are deliberately outside this recorder.
#[derive(Clone, Default)]
pub struct InputReads(Arc<Mutex<InputReadSet>>);
#[derive(Default)]
struct InputReadSet { entries: std::collections::BTreeSet<(u8, String)>, bytes: usize, exceeded: bool }
impl InputReads {
    fn record(&self, kind: u8, path: &str) -> Result<(), Error> {
        let mut reads = self.0.lock().unwrap();
        let entry = (kind, path.to_string());
        if reads.entries.contains(&entry) { return Ok(()); }
        if reads.entries.len() >= 32_768 || reads.bytes + path.len() + 3 > 4 * 1024 * 1024 { reads.exceeded = true; return Err(Error::io()); }
        reads.bytes += path.len() + 3; reads.entries.insert(entry); Ok(())
    }
    pub fn bytes(&self) -> Result<Vec<u8>, String> {
        let reads = self.0.lock().unwrap();
        if reads.exceeded { return Err("typesetter_dependency_limit".into()); }
        let mut bytes = Vec::with_capacity(reads.bytes);
        for (kind, path) in reads.entries.iter() {
            bytes.push(*kind); bytes.push(0); bytes.extend_from_slice(path.as_bytes()); bytes.push(0);
        }
        Ok(bytes)
    }
}

#[derive(Clone)]
pub struct Directory {
    files: Arc<Mutex<BTreeMap<String, SharedBuffer>>>,
    prefix: String,
    directories: Arc<Mutex<std::collections::BTreeSet<String>>>,
    bundle: Option<Arc<Bundle>>, fonts_only: bool, writable: bool, budget: Arc<Budget>,
    resources: Option<Arc<ResourceCache>>,
    input_reads: Option<InputReads>,
}
impl Directory {
    pub fn new(writable: bool, budget: &Arc<Budget>) -> Self { Self { files: Default::default(), prefix: String::new(), directories: Default::default(), bundle: None, fonts_only: false, writable, budget: budget.clone(), resources: None, input_reads: None } }
    pub fn tracked_input(budget: &Arc<Budget>) -> (Self, InputReads) {
        let reads = InputReads::default();
        (Self { input_reads: Some(reads.clone()), ..Self::new(false, budget) }, reads)
    }
    fn record(&self, kind: u8, path: &str) -> Result<(), Error> {
        if let Some(reads) = &self.input_reads { reads.record(kind, path)?; }
        Ok(())
    }
    pub fn bundle(bundle: Arc<Bundle>, fonts_only: bool, budget: &Arc<Budget>, resources: &Arc<ResourceCache>) -> Self {
        Self { bundle: Some(bundle), fonts_only, resources: Some(resources.clone()), ..Self::new(false, budget) }
    }
    pub fn put(&self, name: &str, bytes: Vec<u8>) -> Result<(), Error> {
        self.put_buffer(name, BufferBytes::Owned(bytes))
    }
    pub fn put_resource(&self, name: &str, bytes: Arc<Vec<u8>>) -> Result<(), Error> {
        if self.writable || self.bundle.is_none() { return Err(Error::not_supported()); }
        self.put_buffer(name, BufferBytes::Pinned(bytes))
    }
    fn put_buffer(&self, name: &str, bytes: BufferBytes) -> Result<(), Error> {
        let name = self.path(name)?;
        let mut files = self.files.lock().unwrap();
        if files.len() >= MAX_ENTRIES && !files.contains_key(&name) { return Err(Error::io()); }
        let prefix = format!("{name}/");
        if files.contains_key(&name)
            || files.range(prefix.clone()..).next().is_some_and(|(path, _)| path.starts_with(&prefix))
            || name.match_indices('/').any(|(at, _)| files.contains_key(&name[..at])) { return Err(Error::exist()); }
        files.insert(name, Arc::new(Mutex::new(Buffer::admit(bytes, &self.budget)?))); Ok(())
    }
    pub fn take(&self, name: &str) -> Option<Vec<u8>> {
        let shared = self.files.lock().unwrap().remove(name)?;
        let mut buffer = shared.lock().unwrap(); let bytes = std::mem::take(buffer.bytes.owned().ok()?);
        buffer.budget.bytes.fetch_sub(bytes.len(), Ordering::Relaxed); Some(bytes)
    }
    pub fn valid_path(name: &str) -> bool {
        !name.is_empty() && name.len() <= 1024 && !name.contains('\\') && !name.contains('\0')
            && name.split('/').count() <= 32
            && name.split('/').all(|p| !p.is_empty() && p != "." && p != "..")
    }
    fn path(&self, name: &str) -> Result<String, Error> {
        let name = name.strip_prefix("./").unwrap_or(name);
        if !Self::valid_path(name) { return Err(Error::not_found()); }
        let name = format!("{}{name}", self.prefix);
        if !Self::valid_path(&name) { return Err(Error::not_found()); }
        Ok(name)
    }
    fn is_directory(&self, path: &str) -> bool {
        let prefix = format!("{path}/");
        self.directories.lock().unwrap().contains(path)
            || self.files.lock().unwrap().range(prefix.clone()..).next().is_some_and(|(name, _)| name.starts_with(&prefix))
    }
    fn child(&self, path: &str) -> Self { Self { prefix: format!("{path}/"), ..self.clone() } }

}
#[wiggle::async_trait]
impl WasiDir for Directory {
    fn as_any(&self) -> &dyn Any { self }
    async fn get_filestat(&self) -> Result<Filestat, Error> { self.record(b'p', self.prefix.trim_end_matches('/'))?; Ok(stat(FileType::Directory, 0)) }
    async fn get_path_filestat(&self, name: &str, _: bool) -> Result<Filestat, Error> {
        if name == "." || name.is_empty() { return self.get_filestat().await; }
        let name = self.path(name)?;
        self.record(b'p', &name)?;
        if self.is_directory(&name) { return Ok(stat(FileType::Directory, 0)); }
        if let Some(file) = self.files.lock().unwrap().get(&name) { return Ok(stat(FileType::RegularFile, file.lock().unwrap().bytes.data().len() as u64)); }
        Ok(stat(FileType::RegularFile, self.bundle.as_ref().ok_or_else(Error::not_found)?.size(&name, &self.budget)?))
    }
    async fn open_file(&self, _: bool, name: &str, flags: OFlags, _: bool, write: bool, fd: FdFlags) -> Result<OpenResult, Error> {
        if name == "." || name.is_empty() { return Ok(OpenResult::Dir(Box::new(self.clone()))); }
        let name = self.path(name)?;
        self.record(b'p', &name)?;
        if (write || flags.intersects(OFlags::CREATE | OFlags::TRUNCATE)) && !self.writable { return Err(Error::not_supported()); }
        if !fd.is_empty() { return Err(Error::not_supported()); }
        if self.is_directory(&name) { return Ok(OpenResult::Dir(Box::new(self.child(&name)))); }
        if flags.contains(OFlags::DIRECTORY) { return Err(Error::not_found()); }
        let mut files = self.files.lock().unwrap();
        let buffer = if let Some(file) = files.get(&name) {
            if flags.contains(OFlags::EXCLUSIVE) { return Err(Error::exist()); }
            if flags.contains(OFlags::TRUNCATE) { file.lock().unwrap().resize(0)?; }
            file.clone()
        } else if self.writable && flags.contains(OFlags::CREATE) {
            if files.len() >= MAX_ENTRIES { return Err(Error::io()); }
            let file = Arc::new(Mutex::new(Buffer::new(Vec::new(), &self.budget)?)); files.insert(name.clone(), file.clone()); file
        } else {
            let bundle = self.bundle.as_ref().ok_or_else(Error::not_found)?;
            let cached = self.resources.as_ref().and_then(|cache| cache.get(&name));
            if let Some(buffer) = cached { buffer }
            else {
                let buffer = bundle.read(&name, &self.budget)?;
                if let Some(cache) = &self.resources { cache.insert(&name, &buffer); }
                buffer
            }
        };
        Ok(OpenResult::File(Box::new(Handle::new(buffer, write, &self.budget)?)))
    }
    async fn readdir(&self, cursor: ReaddirCursor) -> Result<Box<dyn Iterator<Item=Result<ReaddirEntity, Error>> + Send>, Error> {
        self.record(b'd', self.prefix.trim_end_matches('/'))?;
        let at = u64::from(cursor) as usize;
        let names = if let Some(bundle) = &self.bundle { bundle.names(self.fonts_only, &self.budget)? }
            else { Arc::new(self.files.lock().unwrap().keys().cloned()
                .chain(self.directories.lock().unwrap().iter().cloned()).collect()) };
        let mut entries = BTreeMap::new();
        for name in names.iter().filter_map(|name| name.strip_prefix(&self.prefix)) {
            let mut parts = name.split('/'); let first = parts.next().unwrap();
            let kind = if parts.next().is_some() || self.directories.lock().unwrap().contains(&format!("{}{first}", self.prefix))
                { FileType::Directory } else { FileType::RegularFile };
            entries.insert(first.to_string(), kind);
        }
        Ok(Box::new(entries.into_iter().enumerate().skip(at).map(|(i, (name, filetype))|
            Ok(ReaddirEntity { next: ((i+1) as u64).into(), inode: (i+1) as u64, name, filetype }))))
    }
    async fn create_dir(&self, name: &str) -> Result<(), Error> {
        if name == "." || name.is_empty() { return Ok(()); }
        if !self.writable { return Err(Error::not_supported()); }
        let name = self.path(name)?;
        if self.files.lock().unwrap().contains_key(&name) { return Err(Error::exist()); }
        let mut directories = self.directories.lock().unwrap();
        if directories.len() >= MAX_ENTRIES { return Err(Error::io()); }
        directories.insert(name); Ok(())
    }

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

#[cfg(test)]
mod bundle_reader_tests {
    use super::*;
    use std::io::Seek;

    struct Fixture(PathBuf);
    impl Fixture {
        fn new(name: &str) -> Self {
            let path = std::env::temp_dir().join(format!("notebook-bundle-reader-{}-{name}", std::process::id()));
            let mut file = File::create_new(&path).unwrap();
            file.write_all(&(0..32781).map(|i| (i * 31 + 17) as u8).collect::<Vec<_>>()).unwrap();
            Self(path)
        }
        fn pair(&self) -> (File, BundleReader) {
            (File::open(&self.0).unwrap(), BundleReader::new(File::open(&self.0).unwrap()).unwrap())
        }
    }
    impl Drop for Fixture { fn drop(&mut self) { std::fs::remove_file(&self.0).unwrap(); } }
    fn compare_seek(file: &mut File, reader: &mut BundleReader, seek: SeekFrom) {
        let expected = file.seek(seek);
        let actual = reader.seek(seek);
        assert_eq!(expected.as_ref().ok(), actual.as_ref().ok(), "{seek:?}");
        assert_eq!(expected.as_ref().err().map(|e| e.kind()), actual.as_ref().err().map(|e| e.kind()), "{seek:?}");
        assert_eq!(file.stream_position().unwrap(), reader.stream_position().unwrap());
    }
    fn compare_read(file: &mut File, reader: &mut BundleReader, length: usize) {
        let mut actual = vec![0; length];
        let start = file.stream_position().unwrap();
        let count = reader.read(&mut actual).unwrap();
        assert!(count <= length);
        if length > 0 && count == 0 { assert!(start >= file.metadata().unwrap().len(), "false EOF"); }
        // Read permits short reads: compare exactly the returned bytes and cursor.
        let mut expected = vec![0; count];
        file.read_exact(&mut expected).unwrap();
        assert_eq!(expected, actual[..count]);
        assert_eq!(file.stream_position().unwrap(), reader.stream_position().unwrap());
    }
    #[test]
    fn position_queries_and_absolute_noop_seeks_keep_readahead() {
        let fixture = Fixture::new("readahead");
        let (mut file, mut reader) = fixture.pair();
        compare_read(&mut file, &mut reader, 30);
        assert_eq!(reader.file.capacity(), ZIP_READER_BUFFER_BYTES);
        let buffered = reader.file.buffer().len();
        assert_eq!(buffered, ZIP_READER_BUFFER_BYTES - 30);
        for _ in 0..1000 {
            assert_eq!(reader.stream_position().unwrap(), 30);
            assert_eq!(reader.seek(SeekFrom::Start(30)).unwrap(), 30);
            assert_eq!(reader.file.buffer().len(), buffered);
        }
        compare_seek(&mut file, &mut reader, SeekFrom::Current(46));
        assert_eq!(reader.file.buffer().len(), buffered - 46);
        compare_read(&mut file, &mut reader, 17);
    }
    #[test]
    fn absolute_relative_end_eof_and_errors_preserve_cursor() {
        let fixture = Fixture::new("seeks");
        let (mut file, mut reader) = fixture.pair();
        compare_read(&mut file, &mut reader, 23);
        for seek in [SeekFrom::Current(0), SeekFrom::Start(23), SeekFrom::Start(5),
            SeekFrom::Current(8180), SeekFrom::Start(8190), SeekFrom::Current(20),
            SeekFrom::Current(-17), SeekFrom::End(-7), SeekFrom::End(100),
            SeekFrom::Current(-90), SeekFrom::Start(0), SeekFrom::Current(-1),
            SeekFrom::End(-100000), SeekFrom::Start(u64::MAX),
            SeekFrom::Current(i64::MAX), SeekFrom::Current(i64::MIN), SeekFrom::Start(17)] {
            compare_seek(&mut file, &mut reader, seek);
            compare_read(&mut file, &mut reader, 3);
        }
        compare_seek(&mut file, &mut reader, SeekFrom::End(-2));
        compare_read(&mut file, &mut reader, 5);
        compare_read(&mut file, &mut reader, 5);
        compare_read(&mut file, &mut reader, 0);
    }
    #[test]
    fn mixed_operations_match_file() {
        let fixture = Fixture::new("mixed");
        let (mut file, mut reader) = fixture.pair();
        let mut random = 918723u64;
        for _ in 0..10000 {
            random = random.wrapping_mul(6364136223846793005).wrapping_add(1);
            match random % 5 {
                0 => compare_seek(&mut file, &mut reader, SeekFrom::Start((random >> 8) % 40000)),
                1 => compare_seek(&mut file, &mut reader, SeekFrom::Current(((random >> 8) % 6000) as i64 - 3000)),
                2 => compare_seek(&mut file, &mut reader, SeekFrom::End(((random >> 8) % 40000) as i64 - 35000)),
                _ => compare_read(&mut file, &mut reader, ((random >> 8) % 20000) as usize),
            }
        }
    }
    #[test]
    fn initial_nonzero_cursor_and_read_exact_partial_eof() {
        let fixture = Fixture::new("initial");
        let mut file = File::open(&fixture.0).unwrap();
        file.seek(SeekFrom::Start(8217)).unwrap();
        let mut owned = File::open(&fixture.0).unwrap();
        owned.seek(SeekFrom::Start(8217)).unwrap();
        let mut reader = BundleReader::new(owned).unwrap();
        compare_read(&mut file, &mut reader, 19);
        compare_seek(&mut file, &mut reader, SeekFrom::End(-7));
        let (mut expected, mut actual) = ([0; 12], [0; 12]);
        assert_eq!(file.read_exact(&mut expected).unwrap_err().kind(), reader.read_exact(&mut actual).unwrap_err().kind());
        assert_eq!(expected, actual);
        assert_eq!(file.stream_position().unwrap(), reader.stream_position().unwrap());
    }
    #[test]
    fn file_read_failure_does_not_publish_false_position() {
        let path = std::env::temp_dir();
        let mut file = File::open(&path).unwrap();
        let mut reader = BundleReader::new(File::open(&path).unwrap()).unwrap();
        let (mut expected, mut actual) = ([0; 4], [0; 4]);
        assert_eq!(file.read(&mut expected).unwrap_err().kind(), reader.read(&mut actual).unwrap_err().kind());
        assert_eq!(file.stream_position().unwrap(), reader.stream_position().unwrap());
    }
    #[test]
    fn nonseekable_handle_is_rejected_at_construction() {
        use std::os::{fd::OwnedFd, unix::net::UnixStream};
        let (stream, _peer) = UnixStream::pair().unwrap();
        let fd: OwnedFd = stream.into();
        assert_eq!(BundleReader::new(File::from(fd)).err().unwrap().kind(), io::ErrorKind::NotSeekable);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{future::Future, pin::pin, task::{Context, Poll, Waker}};
    fn ready<T>(future: impl Future<Output = T>) -> T {
        match pin!(future).poll(&mut Context::from_waker(Waker::noop())) {
            Poll::Ready(value) => value, Poll::Pending => panic!("the capability filesystem must not block"),
        }
    }
    #[test]
    fn nested_inputs_are_read_only_and_paths_cannot_escape() {
        let directory = Directory::new(false, &Arc::new(Budget::default()));
        directory.put("chapters/one.tex", b"Chapter".to_vec()).unwrap();
        for name in ["../private", "/private", "chapters/../../private", "chapters//one", "chapters/./one", "a\\b", "a\0b"] {
            assert!(!Directory::valid_path(name), "{name:?}");
            assert!(ready(directory.get_path_filestat(name, false)).is_err());
        }
        assert_eq!(ready(directory.get_path_filestat("chapters", false)).unwrap().filetype, FileType::Directory);
        let OpenResult::Dir(child) = ready(directory.open_file(false, "chapters", OFlags::DIRECTORY, true, false, FdFlags::empty())).unwrap() else { panic!() };
        let OpenResult::File(file) = ready(child.open_file(false, "one.tex", OFlags::empty(), true, false, FdFlags::empty())).unwrap() else { panic!() };
        let mut data = [0; 7]; assert_eq!(ready(file.read_vectored(&mut [io::IoSliceMut::new(&mut data)])).unwrap(), 7);
        assert_eq!(&data, b"Chapter");
        assert!(ready(child.open_file(false, "one.tex", OFlags::TRUNCATE, true, true, FdFlags::empty())).is_err());
        assert!(ready(child.open_file(false, "../one.tex", OFlags::empty(), true, false, FdFlags::empty())).is_err());
    }
    #[test]
    fn namespace_rejects_duplicates_and_file_directory_collisions() {
        let names = ["a-plain.tex", "a.b.tex", "a/b.tex", "ab.tex"];
        for order in [names.to_vec(), names.into_iter().rev().collect()] {
            let directory = Directory::new(false, &Arc::new(Budget::default()));
            for name in order { directory.put(name, vec![]).unwrap(); }
            assert!(directory.put("a/b.tex", vec![]).is_err());
            assert!(directory.put("a", vec![]).is_err());
            assert!(directory.put("a/b.tex/c", vec![]).is_err());
            assert_eq!(ready(directory.get_path_filestat("a", false)).unwrap().filetype, FileType::Directory);
            assert!(ready(directory.get_path_filestat("a-", false)).is_err());
            let entries: Vec<_> = ready(directory.readdir(0u64.into())).unwrap().map(|v| v.unwrap().name).collect();
            assert_eq!(entries, ["a", "a-plain.tex", "a.b.tex", "ab.tex"]);
        }
        let directory = Directory::new(false, &Arc::new(Budget::default()));
        directory.put("a", vec![]).unwrap();
        assert!(directory.put("a/b.tex", vec![]).is_err());
    }

    #[test]
    fn archive_entries_require_complete_bytes_and_matching_crc() {
        #[derive(Clone, Copy)]
        enum Damage { None, Checksum, Size(u32) }
        let content = b"Immutable archive payload";
        let cases: [(&str, &[u8], Damage); 6] = [
            ("valid", content, Damage::None), ("checksum", content, Damage::Checksum),
            ("short", content, Damage::Size(content.len() as u32 - 1)),
            ("long", content, Damage::Size(content.len() as u32 + 1)),
            ("empty", b"", Damage::None), ("empty-checksum", b"", Damage::Checksum),
        ];
        for method in [zip::CompressionMethod::Stored, zip::CompressionMethod::Deflated] {
            for (case, source, damage) in cases {
                let mut zip = zip::ZipWriter::new(io::Cursor::new(Vec::new()));
                zip.start_file("entry.sty", zip::write::SimpleFileOptions::default().compression_method(method)).unwrap();
                zip.write_all(source).unwrap();
                let mut bytes = zip.finish().unwrap().into_inner();
                let central = bytes.windows(4).position(|v| v == b"PK\x01\x02").unwrap();
                match damage {
                    Damage::None => {},
                    Damage::Checksum => bytes[central + 16] ^= 1,
                    Damage::Size(size) => bytes[central + 24..central + 28].copy_from_slice(&size.to_le_bytes()),
                }
                let path = std::env::temp_dir().join(format!("notebook-archive-validation-{}-{method:?}-{case}.zip", std::process::id()));
                File::create_new(&path).unwrap().write_all(&bytes).unwrap();
                let budget = Arc::new(Budget::default());
                let result = Bundle::new(&path).read("entry.sty", &budget);
                std::fs::remove_file(path).unwrap();
                if matches!(damage, Damage::None) {
                    let buffer = result.unwrap();
                    assert_eq!(buffer.lock().unwrap().bytes.data(), source);
                    assert!(budget.resource_failure().is_none());
                    drop(buffer);
                } else {
                    assert!(result.is_err(), "{method:?}/{case} must fail before caching its bytes");
                    assert!(budget.resource_failure().is_some(), "{method:?}/{case} must fail the physical run");
                }
                assert_eq!(budget.bytes.load(Ordering::Relaxed), 0, "{method:?}/{case} retains a byte charge");
            }
        }
    }
    #[test]
    fn entry_budget_does_not_reduce_open_handle_budget() {
        let budget = Arc::new(Budget::default());
        let directory = Directory::new(false, &budget);
        for i in 0..256 { directory.put(&format!("chapters/{i}.tex"), vec![0]).unwrap(); }
        assert_eq!(budget.bytes.load(Ordering::Relaxed), 256);
        assert_eq!(budget.handles.load(Ordering::Relaxed), 0);
        drop(directory); assert_eq!(budget.bytes.load(Ordering::Relaxed), 0);
    }

    #[test]
    fn pinned_resource_borrows_bytes_and_releases_its_compile_charge() {
        let path = std::env::temp_dir().join(format!("notebook-resource-borrow-{}", std::process::id()));
        std::fs::write(&path, b"Immutable format").unwrap();
        let resource = ResourceFile::new(&path, 1024);
        let bytes = resource.bytes().unwrap();
        assert!(Arc::ptr_eq(&bytes, &resource.bytes().unwrap()));
        // A loaded runtime is bound to the admitted resource bytes, not a later
        // filesystem replacement or a fresh copy made for the next document.
        std::fs::remove_file(&path).unwrap();
        let budget = Arc::new(Budget::default());
        let cache = ResourceCache::new(&budget);
        let directory = Directory::bundle(Arc::new(Bundle::new(&path)), false, &budget, &cache);
        directory.put_resource("latex.fmt", resource.bytes().unwrap()).unwrap();
        let shared = directory.files.lock().unwrap()["latex.fmt"].clone();
        {
            let file = shared.lock().unwrap();
            let BufferBytes::Pinned(mounted) = &file.bytes else { panic!("format copied") };
            assert!(Arc::ptr_eq(&bytes, mounted));
        }
        let OpenResult::File(file) = ready(directory.open_file(false, "latex.fmt", OFlags::empty(), true, false, FdFlags::empty())).unwrap() else { panic!() };
        let mut actual = [0; 16];
        let count = ready(file.read_vectored(&mut [io::IoSliceMut::new(&mut actual)])).unwrap();
        assert_eq!(&actual[..count as usize], bytes.as_slice());
        assert!(ready(file.write_vectored(&[io::IoSlice::new(b"changed")])).is_err());
        assert!(ready(file.set_filestat_size(1)).is_err());
        assert!(ready(directory.open_file(false, "latex.fmt", OFlags::TRUNCATE, true, true, FdFlags::empty())).is_err());
        assert_eq!(budget.bytes.load(Ordering::Relaxed), bytes.len());
        drop(file); drop(shared); drop(directory);
        assert_eq!(budget.bytes.load(Ordering::Relaxed), 0);
        assert!(Arc::ptr_eq(&bytes, &resource.bytes().unwrap()));
    }

    #[test]
    fn inflated_resources_share_across_mounts_only_until_compile_finishes() {
        let path = std::env::temp_dir().join(format!("notebook-resource-reuse-{}.zip", std::process::id()));
        let mut zip = zip::ZipWriter::new(File::create_new(&path).unwrap());
        zip.start_file("face.otf", zip::write::SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated)).unwrap();
        zip.write_all(b"One immutable package").unwrap(); zip.finish().unwrap();
        let budget = Arc::new(Budget::default());
        let cache = ResourceCache::new(&budget);
        let bundle = Arc::new(Bundle::new(&path));
        let packages = Directory::bundle(bundle.clone(), false, &budget, &cache);
        let fonts = Directory::bundle(bundle, true, &budget, &cache);
        let open = |directory: &Directory| {
            let OpenResult::File(file) = ready(directory.open_file(false, "face.otf", OFlags::empty(), true, false, FdFlags::empty())).unwrap() else { panic!() };
            file
        };
        let first = open(&packages);
        let weak = Arc::downgrade(&first.as_any().downcast_ref::<Handle>().unwrap().buffer);
        drop(first); // Reopening after TeX closes a file must reuse its inflation.
        let second = open(&fonts);
        assert!(Arc::ptr_eq(&weak.upgrade().unwrap(), &second.as_any().downcast_ref::<Handle>().unwrap().buffer));
        assert_eq!(budget.bytes.load(Ordering::Relaxed), b"One immutable package".len());
        drop(second); drop(packages); drop(fonts); drop(cache);
        assert!(weak.upgrade().is_none());
        assert_eq!(budget.bytes.load(Ordering::Relaxed), 0);
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn idle_inflation_yields_to_output_growth_without_reclaiming_open_files() {
        let budget = Arc::new(Budget::default());
        let cache = ResourceCache::new(&budget);
        let pinned = Arc::new(Mutex::new(Buffer::new(vec![0; 1024], &budget).unwrap()));
        cache.insert("open.sty", &pinned);
        let idle = Arc::new(Mutex::new(Buffer::new(vec![0; 1024], &budget).unwrap()));
        cache.insert("closed.sty", &idle); let weak = Arc::downgrade(&idle); drop(idle);
        // Stand in for already charged source/output storage without making a
        // unit test allocate 64 MiB. Admission still runs the production policy.
        let occupied = MAX_FILES - 2048;
        budget.bytes.fetch_add(occupied, Ordering::Relaxed);
        budget.acquire_bytes(1024).unwrap();
        assert!(weak.upgrade().is_none());
        assert!(cache.get("open.sty").is_some());
        assert_eq!(budget.bytes.load(Ordering::Relaxed), MAX_FILES);
        assert!(budget.acquire_bytes(1).is_err());
        budget.bytes.fetch_sub(occupied + 1024, Ordering::Relaxed);
        drop(pinned); drop(cache);
        assert_eq!(budget.bytes.load(Ordering::Relaxed), 0);
    }
}
