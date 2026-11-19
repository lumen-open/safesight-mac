// SPDX-License-Identifier: Apache-2.0
//! The keeper store on disk (SD-022, SD-028, SD-225; chapter 02 sections 8 and 13;
//! register 8b), and the local capsule folder.
//!
//! One folder, passed in. The hands layer makes it root-owned with mode 0700 and excludes
//! it from backups. This module refuses a folder, or any folder above it, that is a link,
//! that is not owned by root, or that anyone but its owner could write to (SD-307). Every
//! file is opened without following a link, and must be a plain file. Three ways of
//! writing:
//!
//! - **Two copies** (`<name>.a`, `<name>.b`) for the wait record now, and later the
//!   keyholder pin and the sealed admin secret: each copy is written to a temporary name,
//!   flushed to storage, renamed over the copy, and the folder is flushed; copy A first,
//!   then copy B. On reading, the valid copy with the higher sequence number wins and the
//!   other is rewritten from it. A copy that cannot be read at all (an I/O error, not a
//!   damaged record) is a fault: nothing is rewritten, so a passing error can never roll a
//!   record back to the older copy.
//! - **Two slots** (`clock.a`, `clock.b`) for the clock record: fixed-size reserved files
//!   written in place. A write goes over the older or damaged slot only; the newer slot is
//!   not touched, so a stop at any moment leaves one valid slot. No field of a new record
//!   may move back (`ClockRecord::may_follow`).
//! - **The request journal**: two pairs of fixed-size reserved files (`journal.a` and
//!   `journal.b`, `journal.c` and `journal.d`), each file a header slot and then entry
//!   slots. Entries are appended in place to the current pair, copy A then copy B, each
//!   flushed before the step it describes may run. When the current pair is full, the
//!   journal is compacted into the other pair: only the newest entry, which holds the
//!   whole state of the newest request, is written there, in both copies, and only then
//!   the other pair's header, with the next epoch, in copy A and then copy B. The header
//!   is the commit: until it is written, the old pair stands whole; after, the new one
//!   does. So every entry is in two copies at every step, and a stop at any step leaves
//!   the journal as it was before the compaction or as it is after it.
//!
//! The local capsule folder (register 8b: root-owned, world-readable) has two reserved
//! slots of its own (`capsule.a`, `capsule.b`).
//!
//! Every read goes through the strict decoders of `records`. A damaged copy is repaired
//! from the other. Both copies damaged is a fault that names the record: never a default
//! and never a fresh record. What follows from it is SD-227's table, per record.
//!
//! Flushing is `File::sync_all`, which on macOS is the full-flush file control
//! (`F_FULLFSYNC`) that chapter 02 section 8 asks for.
//!
//! Not here: replaying the journal at start-up (OPEN item 3 of the status document: the
//! entry lacks fields that replay needs), the exit journal and the "next" secret slot
//! (their sizes are not specified), and the sealed admin secret.

use std::fs::{self, File, OpenOptions};
use std::io::{ErrorKind, Read, Write};
use std::os::unix::fs::{FileExt, MetadataExt, OpenOptionsExt};
use std::path::{Component, Path, PathBuf};

use crate::frame::RecordError;
use crate::records::{Capsule, ClockRecord, JournalEntry, JournalHeader, WaitRecord};

/// Which record a store result is about.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecordName {
    WaitRecord,
    ClockRecord,
    Journal,
    Capsule,
}

/// Why the store did not do what was asked. A refused write leaves what was there.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StoreError {
    /// The folder, or a folder above it, is missing, is not a folder, is a link, is not
    /// owned by root, or others can write to it. Or the path is not absolute and plain.
    FolderNotPrivate,
    /// A file operation failed, or a file is not a plain file. Nothing was rewritten.
    Io(ErrorKind),
    /// Neither copy has ever been written. Only Lock writes a first copy. After Lock the
    /// caller treats this exactly as `BothUnreadable` (SD-227).
    NoCopy(RecordName),
    /// Neither copy is a valid record: a fault, never a default.
    BothUnreadable(RecordName),
    /// Both copies are valid with the same sequence number, and they differ: a fault.
    CopiesDisagree(RecordName),
    /// The new record does not follow the current one: its sequence number is not one
    /// more, or a field that only moves forward would move back.
    NotNext(RecordName),
    /// A first write found the record, or a reserved file, already there.
    AlreadyExists(RecordName),
    /// The record's own encoder refused it.
    Record(RecordError),
    /// The bytes read back are not the bytes written.
    ReadBack(RecordName),
    /// A reserved file is missing or is not its fixed size.
    NotReserved(RecordName),
    /// The journal has no free slot even after compaction. Cannot happen with two or
    /// more entry slots; kept so that it is a refusal and never a panic.
    JournalFull,
    /// An entry before the journal's last one is damaged in both copies.
    JournalHole,
}

fn io(error: std::io::Error) -> StoreError {
    StoreError::Io(error.kind())
}

/// The number of entry slots in each copy of the request journal. Each file has one more
/// slot in front, for the header.
// OPEN: SD-225 / C02-18 - the size of the reserved journal file is not specified, and
// neither is what happens when it is full. Working value: 2,048 entries, about 244 KB a
// file, four files. A full pair is compacted into the other (see the module comment).
pub const JOURNAL_SLOTS: usize = 2_048;

/// What a load did besides reading.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Repair {
    /// Both copies were good.
    None,
    /// A damaged, missing or older copy was rewritten from the good one.
    Done,
    /// The good copy was used, and rewriting the other failed. It is tried again at the
    /// next load.
    Failed(ErrorKind),
}

/// A record read from two copies.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Loaded<R> {
    pub record: R,
    pub repair: Repair,
}

/// A record kept as two whole copies.
pub trait TwoCopyRecord: Sized {
    const NAME: RecordName;
    /// The file stem: copies are `<stem>.a` and `<stem>.b`.
    const STEM: &'static str;
    fn encode_record(&self) -> Result<Vec<u8>, RecordError>;
    fn decode_record(bytes: &[u8]) -> Result<Self, RecordError>;
    fn sequence(&self) -> u64;
}

impl TwoCopyRecord for WaitRecord {
    const NAME: RecordName = RecordName::WaitRecord;
    const STEM: &'static str = "wait";
    fn encode_record(&self) -> Result<Vec<u8>, RecordError> {
        self.encode()
    }
    fn decode_record(bytes: &[u8]) -> Result<WaitRecord, RecordError> {
        WaitRecord::decode(bytes)
    }
    fn sequence(&self) -> u64 {
        self.sequence
    }
}

/// Whose folders the store accepts.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Owner {
    /// The real configuration: the folder and every folder above it owned by root.
    Root,
    /// Tests only: the folder's own owner, or root, so that the tests run as a normal
    /// user in a scratch folder. This variant does not exist outside `cfg(test)`, so no
    /// release build can reach it.
    #[cfg(test)]
    TestUser(u32),
}

impl Owner {
    fn accepts(self, uid: u32) -> bool {
        match self {
            Owner::Root => uid == 0,
            #[cfg(test)]
            Owner::TestUser(user) => uid == user || uid == 0,
        }
    }

    /// Whether a root-owned folder above, writable by all but with the sticky bit (as
    /// `/private/tmp`), is accepted. Never in the real configuration.
    fn allows_sticky_parent(self) -> bool {
        match self {
            Owner::Root => false,
            #[cfg(test)]
            Owner::TestUser(_) => true,
        }
    }
}

const WRITABLE_BY_OTHERS: u32 = 0o022;
const STICKY: u32 = 0o1000;

/// True if `dir` is an absolute, plain path to a real folder, not a link, owned as
/// `owner` asks and writable by its owner only; and every folder above it is the same,
/// so that nobody else can replace it or anything in it (SD-307).
fn folder_is_private(dir: &Path, owner: Owner) -> bool {
    if !dir.is_absolute() {
        return false;
    }
    for part in dir.components() {
        match part {
            Component::RootDir | Component::Normal(_) => {}
            _ => return false,
        }
    }
    let meta = match fs::symlink_metadata(dir) {
        Ok(m) => m,
        Err(_) => return false,
    };
    if meta.file_type().is_symlink() || !meta.file_type().is_dir() {
        return false;
    }
    if meta.mode() & WRITABLE_BY_OTHERS != 0 || !owner.accepts(meta.uid()) {
        return false;
    }
    for above in dir.ancestors().skip(1) {
        let m = match fs::symlink_metadata(above) {
            Ok(m) => m,
            Err(_) => return false,
        };
        if m.file_type().is_symlink() || !m.file_type().is_dir() || !owner.accepts(m.uid()) {
            return false;
        }
        if m.mode() & WRITABLE_BY_OTHERS != 0 {
            let sticky_root = m.mode() & STICKY != 0 && m.uid() == 0;
            if !(sticky_root && owner.allows_sticky_parent()) {
                return false;
            }
        }
    }
    true
}

/// The flags every store file is opened with: never through a link, and never waiting on
/// something that is not a plain file.
const OPEN_FLAGS: i32 = libc::O_NOFOLLOW | libc::O_NONBLOCK;

fn not_a_plain_file() -> std::io::Error {
    std::io::Error::new(ErrorKind::Other, "not a plain file")
}

fn plain(file: File) -> std::io::Result<File> {
    if file.metadata()?.file_type().is_file() {
        Ok(file)
    } else {
        Err(not_a_plain_file())
    }
}

fn open_existing(path: &Path, write: bool) -> std::io::Result<File> {
    let file = OpenOptions::new().read(true).write(write).custom_flags(OPEN_FLAGS).open(path)?;
    plain(file)
}

fn read_file(path: &Path) -> std::io::Result<Vec<u8>> {
    let mut file = open_existing(path, false)?;
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes)?;
    Ok(bytes)
}

/// True if anything is at `path`, a link included.
fn present(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok()
}

fn sync_folder(dir: &Path) -> Result<(), StoreError> {
    let folder = OpenOptions::new().read(true).custom_flags(OPEN_FLAGS).open(dir).map_err(io)?;
    folder.sync_all().map_err(io)
}

/// One file as found: absent, or its bytes.
enum Found {
    Absent,
    Bytes(Vec<u8>),
}

/// A missing file is absent. Any other failure to read it is a fault, never "damaged":
/// the other copy is not taken and nothing is rewritten.
fn read_found(path: &Path) -> Result<Found, StoreError> {
    match read_file(path) {
        Ok(bytes) => Ok(Found::Bytes(bytes)),
        Err(e) => {
            if e.kind() == ErrorKind::NotFound {
                Ok(Found::Absent)
            } else {
                Err(io(e))
            }
        }
    }
}

/// Writes `bytes` as the whole of `path`: a temporary file in the same folder, flushed,
/// renamed over `path`, the folder flushed, then read back and compared. A stop leaves
/// the old file or the new one, never a mixture.
fn write_whole(dir: &Path, path: &Path, bytes: &[u8], mode: u32, name: RecordName) -> Result<(), StoreError> {
    let mut temporary = path.as_os_str().to_owned();
    temporary.push(".new");
    let temporary = PathBuf::from(temporary);
    {
        let file = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(mode)
            .custom_flags(OPEN_FLAGS)
            .open(&temporary)
            .map_err(io)?;
        let mut file = plain(file).map_err(io)?;
        file.write_all(bytes).map_err(io)?;
        file.sync_all().map_err(io)?;
    }
    fs::rename(&temporary, path).map_err(io)?;
    sync_folder(dir)?;
    match read_file(path) {
        Ok(back) => {
            if back == bytes {
                Ok(())
            } else {
                Err(StoreError::ReadBack(name))
            }
        }
        Err(e) => Err(io(e)),
    }
}

/// Writes `bytes` in place at `offset` of a reserved file of exactly `size` bytes, flushes,
/// reads back and compares. The file is never grown.
fn write_in_place(path: &Path, size: usize, offset: usize, bytes: &[u8], name: RecordName) -> Result<(), StoreError> {
    let end = match offset.checked_add(bytes.len()) {
        Some(e) => e,
        None => return Err(StoreError::NotReserved(name)),
    };
    if end > size {
        return Err(StoreError::NotReserved(name));
    }
    let file = match open_existing(path, true) {
        Ok(f) => f,
        Err(e) => {
            if e.kind() == ErrorKind::NotFound {
                return Err(StoreError::NotReserved(name));
            }
            return Err(io(e));
        }
    };
    let length = file.metadata().map_err(io)?.len();
    if length != size as u64 {
        return Err(StoreError::NotReserved(name));
    }
    file.write_all_at(bytes, offset as u64).map_err(io)?;
    file.sync_all().map_err(io)?;
    let mut back = vec![0u8; bytes.len()];
    file.read_exact_at(&mut back, offset as u64).map_err(io)?;
    if back != bytes {
        return Err(StoreError::ReadBack(name));
    }
    Ok(())
}

/// Reads a reserved file whole, refusing one that is missing or not its fixed size.
fn read_reserved(path: &Path, size: usize, name: RecordName) -> Result<Vec<u8>, StoreError> {
    match read_file(path) {
        Ok(bytes) => {
            if bytes.len() == size {
                Ok(bytes)
            } else {
                Err(StoreError::NotReserved(name))
            }
        }
        Err(e) => {
            if e.kind() == ErrorKind::NotFound {
                Err(StoreError::NotReserved(name))
            } else {
                Err(io(e))
            }
        }
    }
}

/// Makes a reserved file of `size` zero bytes. Refuses if anything is there already.
fn reserve_file(path: &Path, size: usize, mode: u32, name: RecordName) -> Result<(), StoreError> {
    let mut file = match OpenOptions::new().write(true).create_new(true).mode(mode).custom_flags(OPEN_FLAGS).open(path) {
        Ok(f) => f,
        Err(e) => {
            if e.kind() == ErrorKind::AlreadyExists {
                return Err(StoreError::AlreadyExists(name));
            }
            return Err(io(e));
        }
    };
    // Real zero bytes, not a hole, so that the space is taken now.
    let block = vec![0u8; 4_096];
    let mut written = 0;
    while written < size {
        let take = if size - written < block.len() { size - written } else { block.len() };
        file.write_all(&block[..take]).map_err(io)?;
        written += take;
    }
    file.sync_all().map_err(io)
}

fn all_zero(bytes: &[u8]) -> bool {
    bytes.iter().all(|b| *b == 0)
}

/// One slot of a reserved file as found.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Slot<R> {
    /// All zero: never written.
    Empty,
    Valid(R, Vec<u8>),
    Damaged,
}

/// One of the journal's two pairs of files. Pair X only ever holds even epochs (its
/// empty header is epoch 0), pair Y only odd ones, so the two never tie.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Pair {
    X,
    Y,
}

impl Pair {
    fn files(self) -> [&'static str; 2] {
        match self {
            Pair::X => ["journal.a", "journal.b"],
            Pair::Y => ["journal.c", "journal.d"],
        }
    }

    fn other(self) -> Pair {
        match self {
            Pair::X => Pair::Y,
            Pair::Y => Pair::X,
        }
    }

    fn of_epoch(epoch: u64) -> Pair {
        if epoch % 2 == 0 {
            Pair::X
        } else {
            Pair::Y
        }
    }
}

/// A header slot as found.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum HeaderSlot {
    Empty,
    Valid(u64),
    Damaged,
}

fn header_slot(bytes: &[u8], pair: Pair) -> HeaderSlot {
    if all_zero(bytes) {
        return HeaderSlot::Empty;
    }
    if bytes.len() < JournalHeader::LEN || !all_zero(&bytes[JournalHeader::LEN..]) {
        return HeaderSlot::Damaged;
    }
    match JournalHeader::decode(&bytes[..JournalHeader::LEN]) {
        Ok(header) => {
            if Pair::of_epoch(header.epoch) == pair {
                HeaderSlot::Valid(header.epoch)
            } else {
                HeaderSlot::Damaged
            }
        }
        Err(_) => HeaderSlot::Damaged,
    }
}

fn header_slot_bytes(epoch: u64) -> Result<Vec<u8>, StoreError> {
    let mut bytes = JournalHeader { epoch }.encode().map_err(StoreError::Record)?;
    bytes.resize(JournalEntry::LEN, 0);
    Ok(bytes)
}

/// One pair's two files and its epoch, as read.
struct PairRead {
    copies: [Vec<u8>; 2],
    /// None: pair Y has never been committed to.
    epoch: Option<u64>,
    /// A copy whose header must be rewritten to the epoch above: 0 for copy A, 1 for B.
    header_repair: Option<usize>,
}

/// One planned write of a compaction, so that the test can stop after any of them.
#[derive(Debug, Clone, PartialEq, Eq)]
struct PlannedWrite {
    file: &'static str,
    offset: usize,
    bytes: Vec<u8>,
}

/// The keeper store.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Store {
    dir: PathBuf,
    journal_slots: usize,
}

/// The reserved files of SD-225 that live in the store, with their fixed sizes. The exit
/// journal (outside the store) and the "next" secret slot have no size yet.
// OPEN: SD-225 / C02-18 - the sizes of the exit journal and of the "next" secret slot are
// not specified, so neither is reserved here.
pub fn reserved_files() -> [(&'static str, usize, RecordName); 6] {
    let journal = (JOURNAL_SLOTS + 1) * JournalEntry::LEN;
    [
        ("clock.a", ClockRecord::LEN, RecordName::ClockRecord),
        ("clock.b", ClockRecord::LEN, RecordName::ClockRecord),
        ("journal.a", journal, RecordName::Journal),
        ("journal.b", journal, RecordName::Journal),
        ("journal.c", journal, RecordName::Journal),
        ("journal.d", journal, RecordName::Journal),
    ]
}

const STORE_FILE_MODE: u32 = 0o600;

impl Store {
    /// The store in `dir`, in the real configuration: `dir` and every folder above it
    /// root-owned, real folders, writable by their owner only.
    pub fn open(dir: &Path) -> Result<Store, StoreError> {
        Store::open_as(dir, Owner::Root, JOURNAL_SLOTS)
    }

    /// Tests only: the store in a scratch folder owned by the user running the tests.
    #[cfg(test)]
    pub(crate) fn open_for_tests(dir: &Path, journal_slots: usize) -> Result<Store, StoreError> {
        let uid = fs::symlink_metadata(dir).map_err(io)?.uid();
        Store::open_as(dir, Owner::TestUser(uid), journal_slots)
    }

    fn open_as(dir: &Path, owner: Owner, journal_slots: usize) -> Result<Store, StoreError> {
        if journal_slots < 2 {
            return Err(StoreError::JournalFull);
        }
        if !folder_is_private(dir, owner) {
            return Err(StoreError::FolderNotPrivate);
        }
        Ok(Store { dir: dir.to_path_buf(), journal_slots })
    }

    fn path(&self, name: &str) -> PathBuf {
        self.dir.join(name)
    }

    /// The size of each journal file: the header slot and the entry slots.
    fn journal_file_size(&self) -> usize {
        (self.journal_slots + 1) * JournalEntry::LEN
    }

    /// At Lock: makes every reserved file at its fixed size, filled with zeros (SD-225).
    /// Refuses if any of them exists, so an existing store is never overwritten.
    pub fn reserve(&self) -> Result<(), StoreError> {
        let mut i = 0;
        let files = reserved_files();
        while i < files.len() {
            let (name, _, record) = files[i];
            if present(&self.path(name)) {
                return Err(StoreError::AlreadyExists(record));
            }
            i += 1;
        }
        i = 0;
        while i < files.len() {
            let (name, size, record) = files[i];
            let size = if record == RecordName::Journal { self.journal_file_size() } else { size };
            reserve_file(&self.path(name), size, STORE_FILE_MODE, record)?;
            i += 1;
        }
        sync_folder(&self.dir)
    }

    // ----- Two copies -----

    fn copy_paths<R: TwoCopyRecord>(&self) -> (PathBuf, PathBuf) {
        (self.path(&format!("{}.a", R::STEM)), self.path(&format!("{}.b", R::STEM)))
    }

    /// Writes the first copies of a record. Only Lock does this. Refuses if either copy
    /// exists.
    pub fn create<R: TwoCopyRecord>(&self, first: &R) -> Result<(), StoreError> {
        let bytes = first.encode_record().map_err(StoreError::Record)?;
        let (a, b) = self.copy_paths::<R>();
        if present(&a) || present(&b) {
            return Err(StoreError::AlreadyExists(R::NAME));
        }
        write_whole(&self.dir, &a, &bytes, STORE_FILE_MODE, R::NAME)?;
        write_whole(&self.dir, &b, &bytes, STORE_FILE_MODE, R::NAME)
    }

    /// Reads a two-copy record. The valid copy with the higher sequence number wins; the
    /// other copy, if damaged, missing or older, is rewritten from it. If either copy
    /// cannot be read at all, that is a fault, and nothing is rewritten.
    pub fn load<R: TwoCopyRecord>(&self) -> Result<Loaded<R>, StoreError> {
        let (a, b) = self.copy_paths::<R>();
        let found_a = read_found(&a)?;
        let found_b = read_found(&b)?;
        let absent_a = matches!(found_a, Found::Absent);
        let absent_b = matches!(found_b, Found::Absent);
        let valid = |found: Found| -> Option<(R, Vec<u8>)> {
            match found {
                Found::Absent => None,
                Found::Bytes(bytes) => match R::decode_record(&bytes) {
                    Ok(record) => Some((record, bytes)),
                    Err(_) => None,
                },
            }
        };
        let copy_a = valid(found_a);
        let copy_b = valid(found_b);
        let (record, good_bytes, rewrite) = match (copy_a, copy_b) {
            (Some((ra, ba)), Some((rb, bb))) => {
                if ra.sequence() == rb.sequence() {
                    if ba == bb {
                        return Ok(Loaded { record: ra, repair: Repair::None });
                    }
                    return Err(StoreError::CopiesDisagree(R::NAME));
                }
                if ra.sequence() > rb.sequence() {
                    (ra, ba, b)
                } else {
                    (rb, bb, a)
                }
            }
            (Some((ra, ba)), None) => (ra, ba, b),
            (None, Some((rb, bb))) => (rb, bb, a),
            (None, None) => {
                if absent_a && absent_b {
                    return Err(StoreError::NoCopy(R::NAME));
                }
                return Err(StoreError::BothUnreadable(R::NAME));
            }
        };
        let repair = match write_whole(&self.dir, &rewrite, &good_bytes, STORE_FILE_MODE, R::NAME) {
            Ok(()) => Repair::Done,
            Err(StoreError::Io(kind)) => Repair::Failed(kind),
            Err(_) => Repair::Failed(ErrorKind::Other),
        };
        Ok(Loaded { record, repair })
    }

    /// Replaces a two-copy record with the next one: its sequence number must be one more
    /// than the current record's. Copy A first, then copy B.
    pub fn replace<R: TwoCopyRecord>(&self, next: &R) -> Result<(), StoreError> {
        let current = self.load::<R>()?;
        if current.record.sequence().checked_add(1) != Some(next.sequence()) {
            return Err(StoreError::NotNext(R::NAME));
        }
        let bytes = next.encode_record().map_err(StoreError::Record)?;
        let (a, b) = self.copy_paths::<R>();
        write_whole(&self.dir, &a, &bytes, STORE_FILE_MODE, R::NAME)?;
        write_whole(&self.dir, &b, &bytes, STORE_FILE_MODE, R::NAME)
    }

    // ----- Two slots: the clock record -----

    fn clock_slot(&self, name: &str) -> Result<Slot<ClockRecord>, StoreError> {
        let bytes = read_reserved(&self.path(name), ClockRecord::LEN, RecordName::ClockRecord)?;
        if all_zero(&bytes) {
            return Ok(Slot::Empty);
        }
        match ClockRecord::decode(&bytes) {
            Ok(record) => Ok(Slot::Valid(record, bytes)),
            Err(_) => Ok(Slot::Damaged),
        }
    }

    /// The current clock record and the slot the next write goes to ("clock.a" or
    /// "clock.b"): the valid slot with the higher sequence number is current.
    fn clock_state(&self) -> Result<(Option<ClockRecord>, &'static str), StoreError> {
        let a = self.clock_slot("clock.a")?;
        let b = self.clock_slot("clock.b")?;
        match (a, b) {
            (Slot::Valid(ra, ba), Slot::Valid(rb, bb)) => {
                if ra.sequence == rb.sequence {
                    if ba == bb {
                        return Ok((Some(ra), "clock.b"));
                    }
                    return Err(StoreError::CopiesDisagree(RecordName::ClockRecord));
                }
                if ra.sequence > rb.sequence {
                    Ok((Some(ra), "clock.b"))
                } else {
                    Ok((Some(rb), "clock.a"))
                }
            }
            (Slot::Valid(ra, _), _) => Ok((Some(ra), "clock.b")),
            (_, Slot::Valid(rb, _)) => Ok((Some(rb), "clock.a")),
            (Slot::Empty, Slot::Empty) => Ok((None, "clock.a")),
            _ => Err(StoreError::BothUnreadable(RecordName::ClockRecord)),
        }
    }

    /// Reads the current clock record: the valid slot with the higher sequence number.
    pub fn load_clock(&self) -> Result<ClockRecord, StoreError> {
        match self.clock_state()? {
            (Some(record), _) => Ok(record),
            (None, _) => Err(StoreError::NoCopy(RecordName::ClockRecord)),
        }
    }

    /// Writes the first clock record, at Lock, into empty reserved slots.
    pub fn create_clock(&self, first: &ClockRecord) -> Result<(), StoreError> {
        let bytes = first.encode().map_err(StoreError::Record)?;
        match self.clock_state()? {
            (None, target) => write_in_place(&self.path(target), ClockRecord::LEN, 0, &bytes, RecordName::ClockRecord),
            (Some(_), _) => Err(StoreError::AlreadyExists(RecordName::ClockRecord)),
        }
    }

    /// Writes the next clock record over the older or damaged slot, in place. Refused
    /// unless it follows the current record: sequence plus one, nothing moving back.
    pub fn write_clock(&self, next: &ClockRecord) -> Result<(), StoreError> {
        let (current, target) = self.clock_state()?;
        let current = match current {
            Some(c) => c,
            None => return Err(StoreError::NoCopy(RecordName::ClockRecord)),
        };
        if !next.may_follow(&current) {
            return Err(StoreError::NotNext(RecordName::ClockRecord));
        }
        let bytes = next.encode().map_err(StoreError::Record)?;
        write_in_place(&self.path(target), ClockRecord::LEN, 0, &bytes, RecordName::ClockRecord)
    }

    // ----- The request journal -----

    fn journal_slot(bytes: &[u8]) -> Slot<JournalEntry> {
        if all_zero(bytes) {
            return Slot::Empty;
        }
        match JournalEntry::decode(bytes) {
            Ok(entry) => Slot::Valid(entry, bytes.to_vec()),
            Err(_) => Slot::Damaged,
        }
    }

    /// Reads one pair's files and works out its epoch. A header valid in one copy is
    /// taken, as an entry is; two valid headers that differ are the trace of a stop between
    /// the two header writes of a compaction, which writes every entry of both copies
    /// before either header, so the higher is taken. A header damaged in one copy and empty
    /// in the other is a header write that never finished: the pair was not committed to.
    fn read_pair(&self, pair: Pair) -> Result<PairRead, StoreError> {
        let size = self.journal_file_size();
        let files = pair.files();
        let a = read_reserved(&self.path(files[0]), size, RecordName::Journal)?;
        let b = read_reserved(&self.path(files[1]), size, RecordName::Journal)?;
        let len = JournalEntry::LEN;
        let ha = header_slot(&a[..len], pair);
        let hb = header_slot(&b[..len], pair);
        let never = match pair {
            Pair::X => Some(0),
            Pair::Y => None,
        };
        let (epoch, header_repair) = match (ha, hb) {
            (HeaderSlot::Valid(ea), HeaderSlot::Valid(eb)) => {
                if ea == eb {
                    (Some(ea), None)
                } else if ea > eb {
                    (Some(ea), Some(1))
                } else {
                    (Some(eb), Some(0))
                }
            }
            (HeaderSlot::Valid(ea), _) => (Some(ea), Some(1)),
            (_, HeaderSlot::Valid(eb)) => (Some(eb), Some(0)),
            (HeaderSlot::Damaged, HeaderSlot::Damaged) => return Err(StoreError::BothUnreadable(RecordName::Journal)),
            _ => (never, None),
        };
        Ok(PairRead { copies: [a, b], epoch, header_repair })
    }

    /// Reads the journal from its current pair. An entry valid in one copy only is taken
    /// and the other copy is repaired. A damaged last entry, in both copies, is a torn
    /// append: it is ignored and the step it would have described is treated as not
    /// started (chapter 02 section 8). A damaged entry before the last is a fault.
    pub fn load_journal(&self) -> Result<JournalState, StoreError> {
        let x = self.read_pair(Pair::X)?;
        let y = self.read_pair(Pair::Y)?;
        let x_epoch = match x.epoch {
            Some(e) => e,
            None => 0,
        };
        let y_epoch = y.epoch;
        let (current, pair, epoch) = match y_epoch {
            Some(ey) if ey > x_epoch => (y, Pair::Y, ey),
            _ => (x, Pair::X, x_epoch),
        };
        let files = pair.files();
        let size = self.journal_file_size();
        let len = JournalEntry::LEN;
        let a = &current.copies[0];
        let b = &current.copies[1];
        let slot_of = |copy: &Vec<u8>, i: usize| -> Vec<u8> { copy[(i + 1) * len..(i + 2) * len].to_vec() };
        // The last slot that is not empty in either copy.
        let mut used = 0;
        let mut i = 0;
        while i < self.journal_slots {
            if !all_zero(&slot_of(a, i)) || !all_zero(&slot_of(b, i)) {
                used = i + 1;
            }
            i += 1;
        }
        let mut entries: Vec<JournalEntry> = Vec::new();
        let mut repairs: Vec<(&'static str, usize, Vec<u8>)> = Vec::new();
        let mut next_slot = used;
        i = 0;
        while i < used {
            let slot_a = Store::journal_slot(&slot_of(a, i));
            let slot_b = Store::journal_slot(&slot_of(b, i));
            match (slot_a, slot_b) {
                (Slot::Valid(ea, ba), Slot::Valid(_, bb)) => {
                    if ba != bb {
                        return Err(StoreError::CopiesDisagree(RecordName::Journal));
                    }
                    entries.push(ea);
                }
                (Slot::Valid(ea, ba), _) => {
                    entries.push(ea);
                    repairs.push((files[1], (i + 1) * len, ba));
                }
                (_, Slot::Valid(eb, bb)) => {
                    entries.push(eb);
                    repairs.push((files[0], (i + 1) * len, bb));
                }
                _ => {
                    if i + 1 == used {
                        next_slot = i;
                    } else {
                        return Err(StoreError::JournalHole);
                    }
                }
            }
            i += 1;
        }
        if let Some(copy) = current.header_repair {
            repairs.push((files[copy], 0, header_slot_bytes(epoch)?));
        }
        let mut repair = Repair::None;
        for (name, offset, bytes) in repairs.iter() {
            match write_in_place(&self.path(name), size, *offset, bytes, RecordName::Journal) {
                Ok(()) => {
                    if repair == Repair::None {
                        repair = Repair::Done;
                    }
                }
                Err(StoreError::Io(kind)) => repair = Repair::Failed(kind),
                Err(_) => repair = Repair::Failed(ErrorKind::Other),
            }
        }
        Ok(JournalState { entries, next_slot, epoch, repair })
    }

    /// The writes that compact a full journal into the other pair, in order: the entry
    /// slots of copy A, then of copy B (the newest entry, then zeros), then the header of
    /// copy A, then of copy B, with the next epoch. Each is flushed and read back.
    fn compaction_plan(&self, state: &JournalState) -> Result<Vec<PlannedWrite>, StoreError> {
        let target = Pair::of_epoch(state.epoch).other();
        let epoch = match state.epoch.checked_add(1) {
            Some(e) => e,
            None => return Err(StoreError::JournalFull),
        };
        let len = JournalEntry::LEN;
        let mut slots = vec![0u8; self.journal_slots * len];
        if let Some(newest) = state.entries.last() {
            let bytes = newest.encode().map_err(StoreError::Record)?;
            slots[..len].copy_from_slice(&bytes);
        }
        let header = header_slot_bytes(epoch)?;
        let files = target.files();
        Ok(vec![
            PlannedWrite { file: files[0], offset: len, bytes: slots.clone() },
            PlannedWrite { file: files[1], offset: len, bytes: slots },
            PlannedWrite { file: files[0], offset: 0, bytes: header.clone() },
            PlannedWrite { file: files[1], offset: 0, bytes: header },
        ])
    }

    fn compact_journal(&self, state: &JournalState) -> Result<(), StoreError> {
        let size = self.journal_file_size();
        for write in self.compaction_plan(state)?.iter() {
            write_in_place(&self.path(write.file), size, write.offset, &write.bytes, RecordName::Journal)?;
        }
        Ok(())
    }

    /// Appends one entry: written and flushed in copy A, then in copy B, of the current
    /// pair. If the pair is full, the journal is compacted into the other pair first.
    /// When this returns `Ok`, the step the entry describes may run.
    pub fn append_journal(&self, entry: &JournalEntry) -> Result<(), StoreError> {
        let bytes = entry.encode().map_err(StoreError::Record)?;
        let mut state = self.load_journal()?;
        if state.next_slot >= self.journal_slots {
            self.compact_journal(&state)?;
            state = self.load_journal()?;
            if state.next_slot >= self.journal_slots {
                return Err(StoreError::JournalFull);
            }
        }
        let files = Pair::of_epoch(state.epoch).files();
        let size = self.journal_file_size();
        let offset = (state.next_slot + 1) * JournalEntry::LEN;
        write_in_place(&self.path(files[0]), size, offset, &bytes, RecordName::Journal)?;
        write_in_place(&self.path(files[1]), size, offset, &bytes, RecordName::Journal)
    }
}

/// The journal as read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct JournalState {
    /// Every entry of the current pair, in the order written.
    pub entries: Vec<JournalEntry>,
    /// The slot the next entry goes to.
    pub next_slot: usize,
    /// The current pair's epoch: 0 before the first compaction, one more at each.
    pub epoch: u64,
    pub repair: Repair,
}

// ---------------------------------------------------------------------------------------
// The local capsule folder
// ---------------------------------------------------------------------------------------

const CAPSULE_FILE_MODE: u32 = 0o644;

/// The local capsule folder: root-owned and world-readable (register 8b), so that the app
/// can read a capsule with or without the keeper. Two reserved slots, written in place.
// OPEN: SD-225 - the ruling reserves "one capsule". Two slots are reserved here instead,
// so that a stop while a capsule is written never leaves the folder without a readable
// capsule; the older slot is written first. The second slot holds at most the previous
// generation, whose secret is retired once its rotation finishes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CapsuleFolder {
    dir: PathBuf,
}

impl CapsuleFolder {
    /// The capsule folder in `dir`, in the real configuration: it and every folder above it
    /// root-owned, real folders that others cannot write to. Others may read it.
    pub fn open(dir: &Path) -> Result<CapsuleFolder, StoreError> {
        CapsuleFolder::open_as(dir, Owner::Root)
    }

    /// Tests only: the folder in a scratch folder owned by the user running the tests.
    #[cfg(test)]
    pub(crate) fn open_for_tests(dir: &Path) -> Result<CapsuleFolder, StoreError> {
        let uid = fs::symlink_metadata(dir).map_err(io)?.uid();
        CapsuleFolder::open_as(dir, Owner::TestUser(uid))
    }

    fn open_as(dir: &Path, owner: Owner) -> Result<CapsuleFolder, StoreError> {
        if !folder_is_private(dir, owner) {
            return Err(StoreError::FolderNotPrivate);
        }
        Ok(CapsuleFolder { dir: dir.to_path_buf() })
    }

    /// At Lock: makes the two capsule slots at `CAPSULE_SIZE`, filled with zeros.
    pub fn reserve(&self) -> Result<(), StoreError> {
        let a = self.dir.join("capsule.a");
        let b = self.dir.join("capsule.b");
        if present(&a) || present(&b) {
            return Err(StoreError::AlreadyExists(RecordName::Capsule));
        }
        reserve_file(&a, Capsule::LEN, CAPSULE_FILE_MODE, RecordName::Capsule)?;
        reserve_file(&b, Capsule::LEN, CAPSULE_FILE_MODE, RecordName::Capsule)?;
        sync_folder(&self.dir)
    }

    fn slot(&self, name: &str) -> Result<Slot<Capsule>, StoreError> {
        let bytes = read_reserved(&self.dir.join(name), Capsule::LEN, RecordName::Capsule)?;
        if all_zero(&bytes) {
            return Ok(Slot::Empty);
        }
        match Capsule::decode(&bytes) {
            Ok(capsule) => Ok(Slot::Valid(capsule, bytes)),
            Err(_) => Ok(Slot::Damaged),
        }
    }

    /// The newest capsule (the valid slot with the higher generation; slot A on a tie) and
    /// the slot the next save goes to.
    fn state(&self) -> Result<(Option<Capsule>, &'static str), StoreError> {
        let a = self.slot("capsule.a")?;
        let b = self.slot("capsule.b")?;
        match (a, b) {
            (Slot::Valid(ca, _), Slot::Valid(cb, _)) => {
                if cb.generation > ca.generation {
                    Ok((Some(cb), "capsule.a"))
                } else {
                    Ok((Some(ca), "capsule.b"))
                }
            }
            (Slot::Valid(ca, _), _) => Ok((Some(ca), "capsule.b")),
            (_, Slot::Valid(cb, _)) => Ok((Some(cb), "capsule.a")),
            (Slot::Empty, Slot::Empty) => Ok((None, "capsule.a")),
            _ => Ok((None, "capsule.a")),
        }
    }

    /// The newest valid capsule. `NoCopy` if none was ever saved; `BothUnreadable` if
    /// both slots are damaged.
    pub fn newest(&self) -> Result<Capsule, StoreError> {
        let a = self.slot("capsule.a")?;
        let b = self.slot("capsule.b")?;
        let both_empty = matches!((&a, &b), (Slot::Empty, Slot::Empty));
        match self.state()? {
            (Some(capsule), _) => Ok(capsule),
            (None, _) => {
                if both_empty {
                    Err(StoreError::NoCopy(RecordName::Capsule))
                } else {
                    Err(StoreError::BothUnreadable(RecordName::Capsule))
                }
            }
        }
    }

    /// Saves a capsule over the slot that does not hold the newest one, then reads it back
    /// and compares the bytes (SD-060). A capsule of an older generation is refused, and so
    /// is one of the same generation with another target: the target does not change
    /// within a generation (SM-05).
    pub fn save(&self, capsule: &Capsule) -> Result<(), StoreError> {
        let bytes = capsule.encode().map_err(StoreError::Record)?;
        let (newest, target) = self.state()?;
        if let Some(newest) = newest {
            if capsule.generation < newest.generation {
                return Err(StoreError::NotNext(RecordName::Capsule));
            }
            if capsule.generation == newest.generation && capsule.target_round != newest.target_round {
                return Err(StoreError::NotNext(RecordName::Capsule));
            }
        }
        write_in_place(&self.dir.join(target), Capsule::LEN, 0, &bytes, RecordName::Capsule)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use crate::capsule::{seal, AdminSecret, RecoveryIdentity, RecoveryRecipients, SealError};
    use crate::fakes::{SeededRandom, TestDir};
    use crate::records::{GuardedRaise, RequestKind, RequestState};

    fn test_store(dir: &TestDir) -> Store {
        Store::open_for_tests(&dir.path, JOURNAL_SLOTS).unwrap()
    }

    /// The byte offset of entry slot `i` in a journal file: after the header slot.
    fn at(i: usize) -> usize {
        (i + 1) * JournalEntry::LEN
    }

    fn wait(sequence: u64, applied: u16) -> WaitRecord {
        WaitRecord {
            sequence,
            applied_wait_days: applied,
            planned_wait_days: None,
            guarded_raise: GuardedRaise::None,
            lock_round: 1_000_000,
            long_wait_earliest_round: 1_000_000 + 7 * 28_800,
            awake_ms_at_lock: 4_000_000,
            private_check_awake_hour: 40,
            last_owner_session_round: None,
            hold: None,
        }
    }

    fn clock(sequence: u64, boot: u64) -> ClockRecord {
        ClockRecord {
            sequence,
            high_water_round: 1_000_000,
            high_water_signature: [0x44; 48],
            high_water_boot_ms: 5_000_000,
            estimate_base_round: 1_000_000,
            estimate_base_boot_ms: 5_000_000,
            boot_total_ms: boot,
            awake_total_ms: 4_000_000,
            last_boot_reading_ms: 70_000,
            last_awake_reading_ms: 60_000,
            boot_session: [0x0B; 16],
        }
    }

    fn entry(n: u8) -> JournalEntry {
        JournalEntry {
            request_id: [n; 16],
            kind: RequestKind::Exit,
            state: RequestState::Pending,
            wait_rounds: 7 * 28_800,
            boot_ms_at_request: 1_000 * n as u64,
            start_round: None,
            target_round: None,
            matured_round: None,
            claim_deadline: None,
            approval_used: false,
            challenge_nonce: [n; 32],
        }
    }

    fn flip(path: &Path, index: usize) {
        let mut bytes = fs::read(path).unwrap();
        bytes[index] ^= 0x01;
        fs::write(path, &bytes).unwrap();
    }

    fn put_at(path: &Path, offset: usize, bytes: &[u8]) {
        let file = OpenOptions::new().write(true).open(path).unwrap();
        file.write_all_at(bytes, offset as u64).unwrap();
    }

    fn mode_of(path: &Path) -> u32 {
        fs::metadata(path).unwrap().permissions().mode() & 0o777
    }

    // ----- The folder -----

    #[test]
    fn a_folder_others_can_write_to_is_refused() {
        let dir = TestDir::new("folder");
        assert!(Store::open_for_tests(&dir.path, JOURNAL_SLOTS).is_ok());
        fs::set_permissions(&dir.path, fs::Permissions::from_mode(0o777)).unwrap();
        assert_eq!(Store::open_for_tests(&dir.path, JOURNAL_SLOTS), Err(StoreError::FolderNotPrivate));
        fs::set_permissions(&dir.path, fs::Permissions::from_mode(0o720)).unwrap();
        assert_eq!(Store::open_for_tests(&dir.path, JOURNAL_SLOTS), Err(StoreError::FolderNotPrivate));
        fs::set_permissions(&dir.path, fs::Permissions::from_mode(0o700)).unwrap();

        // A link to a private folder, a file, and nothing at all.
        let link = dir.path.join("link");
        let inner = dir.path.join("inner");
        fs::create_dir(&inner).unwrap();
        fs::set_permissions(&inner, fs::Permissions::from_mode(0o700)).unwrap();
        std::os::unix::fs::symlink(&inner, &link).unwrap();
        assert_eq!(Store::open_for_tests(&link, JOURNAL_SLOTS), Err(StoreError::FolderNotPrivate));
        let file = dir.path.join("file");
        fs::write(&file, b"x").unwrap();
        assert_eq!(Store::open_for_tests(&file, JOURNAL_SLOTS), Err(StoreError::FolderNotPrivate));
        assert!(Store::open_for_tests(&dir.path.join("missing"), JOURNAL_SLOTS).is_err());
        assert_eq!(CapsuleFolder::open(&dir.path.join("missing")), Err(StoreError::FolderNotPrivate));
        assert_eq!(Store::open(&dir.path.join("missing")), Err(StoreError::FolderNotPrivate));
    }

    // SD-307: in the real configuration the folder and every folder above it must be
    // owned by root. The tests run as a normal user, so the real configuration refuses
    // their scratch folder; only the test-only option, which no release build has,
    // accepts it.
    #[test]
    fn the_real_configuration_takes_only_root_owned_folders() {
        let dir = TestDir::new("root-only");
        let uid = fs::metadata(&dir.path).unwrap().uid();
        if uid != 0 {
            assert_eq!(Store::open(&dir.path), Err(StoreError::FolderNotPrivate));
            fs::set_permissions(&dir.path, fs::Permissions::from_mode(0o755)).unwrap();
            assert_eq!(CapsuleFolder::open(&dir.path), Err(StoreError::FolderNotPrivate));
        }
        assert!(Store::open_for_tests(&dir.path, JOURNAL_SLOTS).is_ok());
        // A path that is not absolute and plain is refused before anything is read.
        assert_eq!(Store::open(Path::new("relative/store")), Err(StoreError::FolderNotPrivate));
        let dotted = dir.path.join("..").join(dir.path.file_name().unwrap());
        let uid = fs::metadata(&dir.path).unwrap().uid();
        assert!(!folder_is_private(&dotted, Owner::TestUser(uid)));
    }

    // Every folder above the store is checked, not only the store's own.
    #[test]
    fn a_folder_above_that_is_a_link_or_writable_by_others_is_refused() {
        let dir = TestDir::new("parents");
        let uid = fs::metadata(&dir.path).unwrap().uid();
        let middle = dir.path.join("middle");
        let store_dir = middle.join("store");
        fs::create_dir(&middle).unwrap();
        fs::create_dir(&store_dir).unwrap();
        fs::set_permissions(&middle, fs::Permissions::from_mode(0o755)).unwrap();
        fs::set_permissions(&store_dir, fs::Permissions::from_mode(0o700)).unwrap();
        assert!(folder_is_private(&store_dir, Owner::TestUser(uid)));
        // A folder above that others can write to, with or without the sticky bit (which
        // only a root-owned folder may have, and only in the test configuration).
        fs::set_permissions(&middle, fs::Permissions::from_mode(0o777)).unwrap();
        assert!(!folder_is_private(&store_dir, Owner::TestUser(uid)));
        fs::set_permissions(&middle, fs::Permissions::from_mode(0o1777)).unwrap();
        assert!(!folder_is_private(&store_dir, Owner::TestUser(uid)));
        fs::set_permissions(&middle, fs::Permissions::from_mode(0o775)).unwrap();
        assert!(!folder_is_private(&store_dir, Owner::TestUser(uid)));
        fs::set_permissions(&middle, fs::Permissions::from_mode(0o755)).unwrap();
        // A link above: the store reached through it is refused, though the folder it
        // points to is fine.
        let linked = dir.path.join("linked");
        std::os::unix::fs::symlink(&middle, &linked).unwrap();
        assert!(!folder_is_private(&linked.join("store"), Owner::TestUser(uid)));
        assert!(folder_is_private(&store_dir, Owner::TestUser(uid)));
        // A folder above owned by someone else (root is accepted) fails the real check.
        assert!(!folder_is_private(&store_dir, Owner::Root) || uid == 0);
    }

    // No store file is ever read or written through a link.
    #[test]
    fn a_store_file_that_is_a_link_is_never_followed() {
        let dir = TestDir::new("file-links");
        let store = test_store(&dir);
        store.create(&wait(3, 30)).unwrap();
        let outside = TestDir::new("file-links-outside");
        let target = outside.path.join("target");
        fs::write(&target, wait(9, 90).encode().unwrap()).unwrap();
        // A copy replaced by a link to a valid record elsewhere: a fault, not that record,
        // and the file it points to is left as it was.
        fs::remove_file(dir.path.join("wait.a")).unwrap();
        std::os::unix::fs::symlink(&target, dir.path.join("wait.a")).unwrap();
        assert!(matches!(store.load::<WaitRecord>(), Err(StoreError::Io(_))));
        assert!(matches!(store.replace(&wait(4, 30)), Err(StoreError::Io(_))));
        assert_eq!(fs::read(&target).unwrap(), wait(9, 90).encode().unwrap());
        // A planted temporary name is not written through either.
        fs::remove_file(dir.path.join("wait.a")).unwrap();
        fs::write(dir.path.join("wait.a"), wait(3, 30).encode().unwrap()).unwrap();
        std::os::unix::fs::symlink(&target, dir.path.join("wait.b.new")).unwrap();
        fs::write(dir.path.join("wait.b"), b"damaged").unwrap();
        let loaded = store.load::<WaitRecord>().unwrap();
        assert_eq!(loaded.record, wait(3, 30));
        assert!(matches!(loaded.repair, Repair::Failed(_)));
        assert_eq!(fs::read(&target).unwrap(), wait(9, 90).encode().unwrap());

        // The reserved files too.
        let dir = TestDir::new("journal-links");
        let store = Store::open_for_tests(&dir.path, 4).unwrap();
        store.reserve().unwrap();
        let target = outside.path.join("journal");
        fs::write(&target, vec![0u8; 5 * JournalEntry::LEN]).unwrap();
        fs::remove_file(dir.path.join("journal.b")).unwrap();
        std::os::unix::fs::symlink(&target, dir.path.join("journal.b")).unwrap();
        assert!(matches!(store.load_journal(), Err(StoreError::Io(_))));
        assert!(matches!(store.append_journal(&entry(1)), Err(StoreError::Io(_))));
        assert!(all_zero(&fs::read(&target).unwrap()));
        fs::remove_file(dir.path.join("clock.a")).unwrap();
        std::os::unix::fs::symlink(&target, dir.path.join("clock.a")).unwrap();
        assert!(matches!(store.load_clock(), Err(StoreError::Io(_))));
    }

    // A copy that cannot be read is a fault: the other copy is not taken, and nothing is
    // rewritten. Before, a passing read error on the newer copy made the older one win and
    // be written over it, so the record went back one step.
    #[test]
    fn a_copy_that_cannot_be_read_is_a_fault_and_rolls_nothing_back() {
        let dir = TestDir::new("read-error");
        let store = test_store(&dir);
        store.create(&wait(3, 7)).unwrap();
        // A stop between the two copies of a replace: A holds sequence 4, B still 3.
        fs::write(dir.path.join("wait.a"), wait(4, 30).encode().unwrap()).unwrap();
        // Copy A can then not be read for a moment.
        fs::set_permissions(dir.path.join("wait.a"), fs::Permissions::from_mode(0o000)).unwrap();
        let readable = fs::read(dir.path.join("wait.a")).is_ok();
        if !readable {
            assert_eq!(store.load::<WaitRecord>(), Err(StoreError::Io(ErrorKind::PermissionDenied)));
            assert_eq!(store.replace(&wait(4, 7)), Err(StoreError::Io(ErrorKind::PermissionDenied)));
            assert_eq!(store.replace(&wait(5, 7)), Err(StoreError::Io(ErrorKind::PermissionDenied)));
        }
        fs::set_permissions(dir.path.join("wait.a"), fs::Permissions::from_mode(0o600)).unwrap();
        // Readable again: the newer record stands, and B is completed from it.
        assert_eq!(store.load::<WaitRecord>().unwrap(), Loaded { record: wait(4, 30), repair: Repair::Done });
        assert_eq!(fs::read(dir.path.join("wait.b")).unwrap(), wait(4, 30).encode().unwrap());

        // Something that is not a plain file in place of a copy (here a folder) is the
        // same fault, whoever runs the test.
        fs::remove_file(dir.path.join("wait.b")).unwrap();
        fs::create_dir(dir.path.join("wait.b")).unwrap();
        assert!(matches!(store.load::<WaitRecord>(), Err(StoreError::Io(_))));
        assert!(dir.path.join("wait.b").is_dir());
        assert_eq!(fs::read(dir.path.join("wait.a")).unwrap(), wait(4, 30).encode().unwrap());
    }

    #[test]
    fn reserve_makes_each_file_once_at_its_fixed_size() {
        let dir = TestDir::new("reserve");
        let store = test_store(&dir);
        store.reserve().unwrap();
        for (name, size, _) in reserved_files().iter() {
            let path = dir.path.join(name);
            let bytes = fs::read(&path).unwrap();
            assert_eq!(bytes.len(), *size, "{}", name);
            assert!(all_zero(&bytes));
            assert_eq!(mode_of(&path), 0o600);
        }
        assert_eq!(reserved_files()[2].1, (2_048 + 1) * JournalEntry::LEN);
        assert_eq!(reserved_files().len(), 6);
        assert_eq!(store.reserve(), Err(StoreError::AlreadyExists(RecordName::ClockRecord)));
    }

    // ----- Two copies -----

    #[test]
    fn two_copies_write_read_back_and_replace() {
        let dir = TestDir::new("two-copies");
        let store = test_store(&dir);
        assert_eq!(store.load::<WaitRecord>(), Err(StoreError::NoCopy(RecordName::WaitRecord)));
        store.create(&wait(1, 7)).unwrap();
        assert_eq!(store.load::<WaitRecord>().unwrap(), Loaded { record: wait(1, 7), repair: Repair::None });
        assert_eq!(fs::read(dir.path.join("wait.a")).unwrap(), wait(1, 7).encode().unwrap());
        assert_eq!(fs::read(dir.path.join("wait.b")).unwrap(), wait(1, 7).encode().unwrap());
        assert_eq!(mode_of(&dir.path.join("wait.a")), 0o600);
        assert!(!dir.path.join("wait.a.new").exists());

        store.replace(&wait(2, 30)).unwrap();
        assert_eq!(store.load::<WaitRecord>().unwrap().record, wait(2, 30));
        assert_eq!(store.create(&wait(1, 7)), Err(StoreError::AlreadyExists(RecordName::WaitRecord)));
    }

    #[test]
    fn a_record_that_does_not_follow_is_refused_and_changes_nothing() {
        let dir = TestDir::new("not-next");
        let store = test_store(&dir);
        store.create(&wait(5, 7)).unwrap();
        assert_eq!(store.replace(&wait(5, 30)), Err(StoreError::NotNext(RecordName::WaitRecord)));
        assert_eq!(store.replace(&wait(7, 30)), Err(StoreError::NotNext(RecordName::WaitRecord)));
        assert_eq!(store.replace(&wait(4, 30)), Err(StoreError::NotNext(RecordName::WaitRecord)));
        // A record its own encoder refuses (no such wait option).
        assert!(matches!(store.replace(&wait(6, 8)), Err(StoreError::Record(_))));
        assert_eq!(store.load::<WaitRecord>().unwrap().record, wait(5, 7));
    }

    #[test]
    fn one_damaged_copy_is_repaired_from_the_other() {
        let dir = TestDir::new("repair");
        let store = test_store(&dir);
        store.create(&wait(3, 30)).unwrap();
        let good = wait(3, 30).encode().unwrap();
        let a = dir.path.join("wait.a");
        let b = dir.path.join("wait.b");

        // A damaged byte in A, then in B.
        flip(&a, 20);
        assert_eq!(store.load::<WaitRecord>().unwrap(), Loaded { record: wait(3, 30), repair: Repair::Done });
        assert_eq!(fs::read(&a).unwrap(), good);
        flip(&b, good.len() - 1);
        assert_eq!(store.load::<WaitRecord>().unwrap().repair, Repair::Done);
        assert_eq!(fs::read(&b).unwrap(), good);

        // A missing copy, a cut-short copy, an empty copy, a record of another type.
        fs::remove_file(&a).unwrap();
        assert_eq!(store.load::<WaitRecord>().unwrap().repair, Repair::Done);
        assert_eq!(fs::read(&a).unwrap(), good);
        fs::write(&b, &good[..good.len() - 3]).unwrap();
        assert_eq!(store.load::<WaitRecord>().unwrap().repair, Repair::Done);
        fs::write(&a, b"").unwrap();
        assert_eq!(store.load::<WaitRecord>().unwrap().repair, Repair::Done);
        fs::write(&b, clock(1, 6_000_000).encode().unwrap()).unwrap();
        assert_eq!(store.load::<WaitRecord>().unwrap(), Loaded { record: wait(3, 30), repair: Repair::Done });
        assert_eq!(fs::read(&a).unwrap(), good);
        assert_eq!(fs::read(&b).unwrap(), good);
        assert_eq!(store.load::<WaitRecord>().unwrap().repair, Repair::None);
    }

    #[test]
    fn a_stop_between_the_two_copies_keeps_the_newer_record() {
        let dir = TestDir::new("stop-between");
        let store = test_store(&dir);
        store.create(&wait(3, 7)).unwrap();
        // The stop came after copy A was renamed into place and before copy B.
        fs::write(dir.path.join("wait.a"), wait(4, 30).encode().unwrap()).unwrap();
        assert_eq!(store.load::<WaitRecord>().unwrap(), Loaded { record: wait(4, 30), repair: Repair::Done });
        assert_eq!(fs::read(dir.path.join("wait.b")).unwrap(), wait(4, 30).encode().unwrap());
        // A stop while the temporary file was written leaves both copies as they were.
        fs::write(dir.path.join("wait.a.new"), b"half a rec").unwrap();
        assert_eq!(store.load::<WaitRecord>().unwrap(), Loaded { record: wait(4, 30), repair: Repair::None });
        store.replace(&wait(5, 30)).unwrap();
        assert_eq!(store.load::<WaitRecord>().unwrap().record, wait(5, 30));
    }

    #[test]
    fn both_copies_damaged_is_a_fault_and_never_a_default() {
        let dir = TestDir::new("both-damaged");
        let store = test_store(&dir);
        store.create(&wait(3, 90)).unwrap();
        flip(&dir.path.join("wait.a"), 14);
        flip(&dir.path.join("wait.b"), 30);
        assert_eq!(store.load::<WaitRecord>(), Err(StoreError::BothUnreadable(RecordName::WaitRecord)));
        // Nothing is written over the damage, and no new record can be put in its place.
        assert_eq!(store.replace(&wait(4, 7)), Err(StoreError::BothUnreadable(RecordName::WaitRecord)));
        assert_eq!(store.create(&wait(1, 7)), Err(StoreError::AlreadyExists(RecordName::WaitRecord)));
        assert_eq!(store.load::<WaitRecord>(), Err(StoreError::BothUnreadable(RecordName::WaitRecord)));
        // One copy damaged and the other gone is the same fault.
        fs::remove_file(dir.path.join("wait.b")).unwrap();
        assert_eq!(store.load::<WaitRecord>(), Err(StoreError::BothUnreadable(RecordName::WaitRecord)));
        // Both gone: no copy, which after Lock the caller treats as the same fault.
        fs::remove_file(dir.path.join("wait.a")).unwrap();
        assert_eq!(store.load::<WaitRecord>(), Err(StoreError::NoCopy(RecordName::WaitRecord)));
        assert_eq!(store.replace(&wait(4, 7)), Err(StoreError::NoCopy(RecordName::WaitRecord)));
    }

    #[test]
    fn two_valid_copies_that_disagree_are_a_fault() {
        let dir = TestDir::new("disagree");
        let store = test_store(&dir);
        store.create(&wait(3, 7)).unwrap();
        fs::write(dir.path.join("wait.b"), wait(3, 30).encode().unwrap()).unwrap();
        assert_eq!(store.load::<WaitRecord>(), Err(StoreError::CopiesDisagree(RecordName::WaitRecord)));
        assert_eq!(store.replace(&wait(4, 7)), Err(StoreError::CopiesDisagree(RecordName::WaitRecord)));
    }

    // ----- Two slots -----

    #[test]
    fn the_clock_record_goes_to_the_older_slot_in_place() {
        let dir = TestDir::new("clock");
        let store = test_store(&dir);
        assert_eq!(store.load_clock(), Err(StoreError::NotReserved(RecordName::ClockRecord)));
        store.reserve().unwrap();
        assert_eq!(store.load_clock(), Err(StoreError::NoCopy(RecordName::ClockRecord)));
        assert_eq!(store.write_clock(&clock(2, 6_000_000)), Err(StoreError::NoCopy(RecordName::ClockRecord)));
        store.create_clock(&clock(1, 6_000_000)).unwrap();
        assert_eq!(store.create_clock(&clock(1, 6_000_000)), Err(StoreError::AlreadyExists(RecordName::ClockRecord)));
        let a = dir.path.join("clock.a");
        let b = dir.path.join("clock.b");
        assert_eq!(fs::read(&a).unwrap(), clock(1, 6_000_000).encode().unwrap());
        assert!(all_zero(&fs::read(&b).unwrap()));

        store.write_clock(&clock(2, 6_060_000)).unwrap();
        assert_eq!(fs::read(&b).unwrap(), clock(2, 6_060_000).encode().unwrap());
        assert_eq!(fs::read(&a).unwrap(), clock(1, 6_000_000).encode().unwrap());
        store.write_clock(&clock(3, 6_120_000)).unwrap();
        assert_eq!(fs::read(&a).unwrap(), clock(3, 6_120_000).encode().unwrap());
        assert_eq!(store.load_clock().unwrap(), clock(3, 6_120_000));
        // The files never grow.
        assert_eq!(fs::metadata(&a).unwrap().len(), ClockRecord::LEN as u64);
        assert_eq!(fs::metadata(&b).unwrap().len(), ClockRecord::LEN as u64);
    }

    #[test]
    fn a_clock_record_that_moves_back_is_refused() {
        let dir = TestDir::new("clock-back");
        let store = test_store(&dir);
        store.reserve().unwrap();
        store.create_clock(&clock(1, 6_000_000)).unwrap();
        assert_eq!(store.write_clock(&clock(2, 5_999_999)), Err(StoreError::NotNext(RecordName::ClockRecord)));
        assert_eq!(store.write_clock(&clock(1, 6_000_001)), Err(StoreError::NotNext(RecordName::ClockRecord)));
        assert_eq!(store.write_clock(&clock(3, 6_000_001)), Err(StoreError::NotNext(RecordName::ClockRecord)));
        let mut lower_round = clock(2, 6_000_001);
        lower_round.high_water_round -= 1;
        lower_round.estimate_base_round -= 1;
        assert_eq!(store.write_clock(&lower_round), Err(StoreError::NotNext(RecordName::ClockRecord)));
        assert_eq!(store.load_clock().unwrap(), clock(1, 6_000_000));
    }

    #[test]
    fn a_torn_or_damaged_clock_slot_leaves_the_other() {
        let dir = TestDir::new("clock-torn");
        let store = test_store(&dir);
        store.reserve().unwrap();
        store.create_clock(&clock(1, 6_000_000)).unwrap();
        store.write_clock(&clock(2, 6_060_000)).unwrap();
        // A stop half-way through writing slot A with record 3.
        let next = clock(3, 6_120_000).encode().unwrap();
        put_at(&dir.path.join("clock.a"), 0, &next[..next.len() / 2]);
        assert_eq!(store.load_clock().unwrap(), clock(2, 6_060_000));
        // The next write goes over the torn slot, and the good one is not touched.
        store.write_clock(&clock(3, 6_120_000)).unwrap();
        assert_eq!(store.load_clock().unwrap(), clock(3, 6_120_000));
        assert_eq!(fs::read(dir.path.join("clock.b")).unwrap(), clock(2, 6_060_000).encode().unwrap());
        // The newer slot damaged: the older one is current, and is never thrown away.
        flip(&dir.path.join("clock.a"), 40);
        assert_eq!(store.load_clock().unwrap(), clock(2, 6_060_000));
        // Both damaged: a fault.
        flip(&dir.path.join("clock.b"), 40);
        assert_eq!(store.load_clock(), Err(StoreError::BothUnreadable(RecordName::ClockRecord)));
        assert_eq!(store.write_clock(&clock(4, 6_180_000)), Err(StoreError::BothUnreadable(RecordName::ClockRecord)));
        assert_eq!(store.create_clock(&clock(1, 6_000_000)), Err(StoreError::BothUnreadable(RecordName::ClockRecord)));
        // A slot file of the wrong size is not a reserved slot.
        fs::write(dir.path.join("clock.b"), clock(2, 6_060_000).encode().unwrap().repeat(2)).unwrap();
        assert_eq!(store.load_clock(), Err(StoreError::NotReserved(RecordName::ClockRecord)));
    }

    // ----- The journal -----

    fn small_store(dir: &TestDir) -> Store {
        let store = Store::open_for_tests(&dir.path, 4).unwrap();
        store.reserve().unwrap();
        store
    }

    #[test]
    fn the_journal_appends_in_place_to_both_copies() {
        let dir = TestDir::new("journal");
        let store = small_store(&dir);
        let empty = store.load_journal().unwrap();
        assert_eq!(empty, JournalState { entries: Vec::new(), next_slot: 0, epoch: 0, repair: Repair::None });
        store.append_journal(&entry(1)).unwrap();
        store.append_journal(&entry(2)).unwrap();
        store.append_journal(&entry(3)).unwrap();
        let state = store.load_journal().unwrap();
        assert_eq!(state.entries, vec![entry(1), entry(2), entry(3)]);
        assert_eq!(state.next_slot, 3);
        let a = fs::read(dir.path.join("journal.a")).unwrap();
        assert_eq!(a, fs::read(dir.path.join("journal.b")).unwrap());
        assert_eq!(a.len(), 5 * JournalEntry::LEN);
        assert!(all_zero(&a[..JournalEntry::LEN]));
        assert_eq!(&a[at(1)..at(2)], &entry(2).encode().unwrap()[..]);
        store.append_journal(&entry(4)).unwrap();
        // Full: the next append compacts into the other pair first.
        store.append_journal(&entry(5)).unwrap();
        let state = store.load_journal().unwrap();
        assert_eq!(state.entries, vec![entry(4), entry(5)]);
        assert_eq!(state.epoch, 1);
        for name in ["journal.a", "journal.b", "journal.c", "journal.d"].iter() {
            assert_eq!(fs::metadata(dir.path.join(name)).unwrap().len(), (5 * JournalEntry::LEN) as u64);
        }
        assert_eq!(fs::read(dir.path.join("journal.c")).unwrap(), fs::read(dir.path.join("journal.d")).unwrap());
    }

    #[test]
    fn a_damaged_journal_entry_is_repaired_from_the_other_copy() {
        let dir = TestDir::new("journal-repair");
        let store = small_store(&dir);
        store.append_journal(&entry(1)).unwrap();
        store.append_journal(&entry(2)).unwrap();
        store.append_journal(&entry(3)).unwrap();
        flip(&dir.path.join("journal.a"), at(1) + 20);
        flip(&dir.path.join("journal.b"), at(2) + 5);
        let state = store.load_journal().unwrap();
        assert_eq!(state.entries, vec![entry(1), entry(2), entry(3)]);
        assert_eq!(state.repair, Repair::Done);
        assert_eq!(fs::read(dir.path.join("journal.a")).unwrap(), fs::read(dir.path.join("journal.b")).unwrap());
        assert_eq!(store.load_journal().unwrap().repair, Repair::None);
    }

    #[test]
    fn a_torn_last_entry_is_ignored_and_written_over() {
        let dir = TestDir::new("journal-torn");
        let store = small_store(&dir);
        store.append_journal(&entry(1)).unwrap();
        // A stop half-way through the second append to copy A.
        let half = entry(2).encode().unwrap();
        put_at(&dir.path.join("journal.a"), at(1), &half[..40]);
        let state = store.load_journal().unwrap();
        assert_eq!(state.entries, vec![entry(1)]);
        assert_eq!(state.next_slot, 1);
        store.append_journal(&entry(2)).unwrap();
        assert_eq!(store.load_journal().unwrap().entries, vec![entry(1), entry(2)]);

        // A stop after copy A and before copy B: the entry was written once, so it stands,
        // and copy B is completed.
        put_at(&dir.path.join("journal.a"), at(2), &entry(3).encode().unwrap());
        let state = store.load_journal().unwrap();
        assert_eq!(state.entries, vec![entry(1), entry(2), entry(3)]);
        assert_eq!(state.repair, Repair::Done);
        assert_eq!(fs::read(dir.path.join("journal.a")).unwrap(), fs::read(dir.path.join("journal.b")).unwrap());
    }

    #[test]
    fn a_journal_hole_or_a_disagreement_is_a_fault() {
        let dir = TestDir::new("journal-hole");
        let store = small_store(&dir);
        store.append_journal(&entry(1)).unwrap();
        store.append_journal(&entry(2)).unwrap();
        store.append_journal(&entry(3)).unwrap();
        // Entry 2 damaged in both copies, with entry 3 after it.
        flip(&dir.path.join("journal.a"), at(1) + 30);
        flip(&dir.path.join("journal.b"), at(1) + 31);
        assert_eq!(store.load_journal(), Err(StoreError::JournalHole));
        assert_eq!(store.append_journal(&entry(4)), Err(StoreError::JournalHole));

        let dir = TestDir::new("journal-disagree");
        let store = small_store(&dir);
        store.append_journal(&entry(1)).unwrap();
        put_at(&dir.path.join("journal.b"), at(0), &entry(9).encode().unwrap());
        assert_eq!(store.load_journal(), Err(StoreError::CopiesDisagree(RecordName::Journal)));

        // A journal file of the wrong size, or missing, is not the reserved file.
        let dir = TestDir::new("journal-size");
        let store = small_store(&dir);
        fs::write(dir.path.join("journal.b"), vec![0u8; 3 * JournalEntry::LEN]).unwrap();
        assert_eq!(store.load_journal(), Err(StoreError::NotReserved(RecordName::Journal)));
        fs::remove_file(dir.path.join("journal.b")).unwrap();
        assert_eq!(store.append_journal(&entry(1)), Err(StoreError::NotReserved(RecordName::Journal)));
    }

    // ----- Compaction -----

    /// A journal of 4 slots that has been compacted `compactions` times and is full again.
    /// Returns the store and how many entries were appended (entries 1 to that number).
    fn full_journal(dir: &TestDir, compactions: usize) -> (Store, u8) {
        let store = small_store(dir);
        let appended = 4 + 3 * compactions as u8;
        let mut n = 1;
        while n <= appended {
            store.append_journal(&entry(n)).unwrap();
            n += 1;
        }
        let state = store.load_journal().unwrap();
        assert_eq!(state.epoch, compactions as u64);
        assert_eq!(state.next_slot, 4);
        (store, appended)
    }

    #[test]
    fn compaction_keeps_the_newest_entry_and_alternates_the_pairs() {
        let dir = TestDir::new("compaction");
        let store = small_store(&dir);
        let mut n: u8 = 1;
        while n <= 40 {
            store.append_journal(&entry(n)).unwrap();
            let state = store.load_journal().unwrap();
            assert_eq!(state.entries.last(), Some(&entry(n)));
            assert_eq!(state.repair, Repair::None);
            n += 1;
        }
        let state = store.load_journal().unwrap();
        // 40 entries in 4 slots: the first compaction after entry 4, then one after every
        // three more.
        assert_eq!(state.epoch, 12);
        assert_eq!(state.entries, vec![entry(37), entry(38), entry(39), entry(40)]);
        // The current pair's two copies are the same bytes, and the files never grew.
        assert_eq!(fs::read(dir.path.join("journal.a")).unwrap(), fs::read(dir.path.join("journal.b")).unwrap());
        for name in ["journal.a", "journal.b", "journal.c", "journal.d"].iter() {
            assert_eq!(fs::metadata(dir.path.join(name)).unwrap().len(), (5 * JournalEntry::LEN) as u64);
        }
    }

    // A stop after every write of a compaction, and half-way through each one: the journal
    // reads as it was before the compaction or as it is after it, never anything else, and
    // the next append always works. In both directions (into pair Y and into pair X), and
    // into a pair that holds an older compaction.
    #[test]
    fn compaction_survives_a_stop_at_every_step() {
        let mut compactions = 0;
        while compactions < 3 {
            let mut done = 0;
            while done <= 4 {
                let mut torn = 0;
                while torn < 2 {
                    if done == 4 && torn == 1 {
                        torn += 1;
                        continue;
                    }
                    let dir = TestDir::new("compaction-stop");
                    let (store, last) = full_journal(&dir, compactions);
                    let before = store.load_journal().unwrap();
                    let plan = store.compaction_plan(&before).unwrap();
                    assert_eq!(plan.len(), 4);
                    let mut w = 0;
                    while w < done {
                        put_at(&dir.path.join(plan[w].file), plan[w].offset, &plan[w].bytes);
                        w += 1;
                    }
                    if torn == 1 {
                        let cut = if plan[done].offset == 0 { JournalHeader::LEN / 2 } else { plan[done].bytes.len() / 2 };
                        put_at(&dir.path.join(plan[done].file), plan[done].offset, &plan[done].bytes[..cut]);
                    }
                    let state = store.load_journal().unwrap();
                    let committed = done >= 3;
                    let case = format!("compactions {} writes {} torn {}", compactions, done, torn);
                    if committed {
                        assert_eq!(state.entries, vec![entry(last)], "{}", case);
                        assert_eq!(state.epoch, compactions as u64 + 1, "{}", case);
                    } else {
                        assert_eq!(state.entries, vec![entry(last - 3), entry(last - 2), entry(last - 1), entry(last)], "{}", case);
                        assert_eq!(state.epoch, compactions as u64, "{}", case);
                    }
                    // Any repair a load makes is made once.
                    assert_eq!(store.load_journal().unwrap().repair, Repair::None, "{}", case);
                    // The next append works, and leaves the same journal either way.
                    store.append_journal(&entry(200)).unwrap();
                    let after = store.load_journal().unwrap();
                    assert_eq!(after.entries, vec![entry(last), entry(200)], "{}", case);
                    assert_eq!(after.epoch, compactions as u64 + 1, "{}", case);
                    torn += 1;
                }
                done += 1;
            }
            compactions += 1;
        }
    }

    #[test]
    fn a_journal_header_that_cannot_be_trusted_is_a_fault_or_is_not_a_commit() {
        // Both copies of a header damaged: the pair's epoch cannot be known. A fault.
        let dir = TestDir::new("header-damaged");
        let (store, _) = full_journal(&dir, 1);
        flip(&dir.path.join("journal.c"), 13);
        flip(&dir.path.join("journal.d"), 14);
        assert_eq!(store.load_journal(), Err(StoreError::BothUnreadable(RecordName::Journal)));
        assert_eq!(store.append_journal(&entry(9)), Err(StoreError::BothUnreadable(RecordName::Journal)));
        // One copy damaged: the other stands, and the damaged one is repaired.
        let dir = TestDir::new("header-one");
        let (store, last) = full_journal(&dir, 1);
        flip(&dir.path.join("journal.c"), 13);
        let state = store.load_journal().unwrap();
        assert_eq!(state.epoch, 1);
        assert_eq!(state.entries.last(), Some(&entry(last)));
        assert_eq!(state.repair, Repair::Done);
        assert_eq!(fs::read(dir.path.join("journal.c")).unwrap(), fs::read(dir.path.join("journal.d")).unwrap());
        // A header of the wrong pair's parity, made valid, is damage, not a commit.
        let dir = TestDir::new("header-parity");
        let (store, last) = full_journal(&dir, 0);
        let wrong = header_slot_bytes(2).unwrap();
        put_at(&dir.path.join("journal.c"), 0, &wrong);
        put_at(&dir.path.join("journal.d"), 0, &wrong);
        assert_eq!(store.load_journal(), Err(StoreError::BothUnreadable(RecordName::Journal)));
        put_at(&dir.path.join("journal.d"), 0, &vec![0u8; JournalEntry::LEN]);
        let state = store.load_journal().unwrap();
        assert_eq!(state.epoch, 0);
        assert_eq!(state.entries.len(), 4);
        assert_eq!(state.entries.last(), Some(&entry(last)));
        // Bytes after the header in its slot are damage too.
        let dir = TestDir::new("header-trailing");
        let (store, _) = full_journal(&dir, 1);
        put_at(&dir.path.join("journal.c"), JournalHeader::LEN + 3, &[1]);
        let state = store.load_journal().unwrap();
        assert_eq!(state.epoch, 1);
        assert_eq!(state.repair, Repair::Done);
    }

    // The flaw this fixes: a journal of fixed size that only appends fills after about a
    // thousand Leave and Stay pairs, and from then on no request could be journaled, so
    // nobody could leave. Here: hundreds of Leave and Stay pairs through the real state
    // machine, into a journal of 8 slots, and then an exit that runs to Committed.
    #[test]
    fn leave_and_stay_without_end_never_stop_an_exit() {
        use crate::approval::MacLabel;
        use crate::boundary::OwnerProof;
        use crate::clock::Clock;
        use crate::fakes::{FakeBeacon, FakeRandom, FakeTime};
        use crate::waits::{LockFacts, Reply, WaitMachine};
        let dir = TestDir::new("journal-cycles");
        let store = Store::open_for_tests(&dir.path, 8).unwrap();
        store.reserve().unwrap();
        let mut time = FakeTime::at_round(1_000_000);
        let clock = Clock::at_lock(&FakeBeacon::record_bytes(1_000_000), &FakeBeacon, &time).unwrap();
        let facts = LockFacts {
            applied_wait_days: 7,
            planned_wait_days: None,
            instant_leave_window: false,
            keyholder_enrolled_before_lock: false,
            mac_label: MacLabel::new("Test Mac").unwrap(),
        };
        let mut m = WaitMachine::at_lock(facts, clock, &time).unwrap();
        let mut random = FakeRandom::new();
        let owner = OwnerProof::TypedPasswordVerified;
        let mut appended = 0;
        let mut cycle = 0;
        while cycle < 300 {
            time.pass_awake_ms(1_000);
            assert!(matches!(m.leave(owner, true, &mut random, &time), Ok(Reply::Pending { .. })));
            m.stay(&time);
            for e in m.take_journal().iter() {
                store.append_journal(e).unwrap();
                appended += 1;
            }
            cycle += 1;
        }
        assert_eq!(appended, 600);
        let id = match m.leave(owner, true, &mut random, &time) {
            Ok(Reply::Pending { id }) => id,
            other => panic!("not pending: {:?}", other),
        };
        time.pass_asleep_ms(7 * 86_400_000);
        m.tick(&time);
        assert_eq!(m.claim(owner, id, &time), Ok(Reply::ExitCommitted { id }));
        for e in m.take_journal().iter() {
            store.append_journal(e).unwrap();
        }
        let state = store.load_journal().unwrap();
        let newest = state.entries.last().unwrap();
        assert_eq!(newest.request_id, id);
        assert_eq!(newest.state, RequestState::Committed);
        assert!(state.epoch > 50);
    }

    // ----- The capsule folder -----

    /// A capsule made by the real sealing function, with a test secret and test key.
    fn test_capsule(generation: u64, target: u64, seed: u8) -> Result<Capsule, SealError> {
        let secret = AdminSecret::from_bytes(&[b'k'; crate::capsule::ADMIN_SECRET_LEN]).unwrap();
        let identity = RecoveryIdentity::from_bytes([0x21u8; 32]);
        let recovery = RecoveryRecipients { current: identity.public(), overlap: None };
        seal(&secret, &recovery, generation, target, &mut SeededRandom::new(seed))
    }

    #[test]
    fn capsules_are_saved_read_back_and_kept_two_deep() {
        let dir = TestDir::new("capsules");
        fs::set_permissions(&dir.path, fs::Permissions::from_mode(0o755)).unwrap();
        let folder = CapsuleFolder::open_for_tests(&dir.path).unwrap();
        assert_eq!(folder.newest(), Err(StoreError::NotReserved(RecordName::Capsule)));
        folder.reserve().unwrap();
        assert_eq!(folder.reserve(), Err(StoreError::AlreadyExists(RecordName::Capsule)));
        assert_eq!(mode_of(&dir.path.join("capsule.a")), 0o644);
        assert_eq!(folder.newest(), Err(StoreError::NoCopy(RecordName::Capsule)));

        let g3 = test_capsule(3, 2_000_000, 1).unwrap();
        folder.save(&g3).unwrap();
        assert_eq!(folder.newest().unwrap(), g3);
        assert_eq!(fs::read(dir.path.join("capsule.a")).unwrap(), g3.encode().unwrap());

        let g4 = test_capsule(4, 2_500_000, 2).unwrap();
        folder.save(&g4).unwrap();
        assert_eq!(folder.newest().unwrap(), g4);
        assert_eq!(fs::read(dir.path.join("capsule.b")).unwrap(), g4.encode().unwrap());
        // The previous generation is still in the other slot.
        assert_eq!(fs::read(dir.path.join("capsule.a")).unwrap(), g3.encode().unwrap());

        // Re-saving the same generation, with the same target, goes over the older slot.
        let g4_again = test_capsule(4, 2_500_000, 3).unwrap();
        folder.save(&g4_again).unwrap();
        assert_eq!(fs::read(dir.path.join("capsule.a")).unwrap(), g4_again.encode().unwrap());
        assert_eq!(fs::read(dir.path.join("capsule.b")).unwrap(), g4.encode().unwrap());

        // An older generation, or the same generation with another target, is refused.
        assert_eq!(folder.save(&test_capsule(3, 2_000_000, 4).unwrap()), Err(StoreError::NotNext(RecordName::Capsule)));
        assert_eq!(folder.save(&test_capsule(4, 2_400_000, 5).unwrap()), Err(StoreError::NotNext(RecordName::Capsule)));
        assert_eq!(fs::metadata(dir.path.join("capsule.a")).unwrap().len(), Capsule::LEN as u64);
    }

    #[test]
    fn a_damaged_capsule_slot_leaves_the_other() {
        let dir = TestDir::new("capsule-damage");
        fs::set_permissions(&dir.path, fs::Permissions::from_mode(0o755)).unwrap();
        let folder = CapsuleFolder::open_for_tests(&dir.path).unwrap();
        folder.reserve().unwrap();
        let g3 = test_capsule(3, 2_000_000, 1).unwrap();
        let g4 = test_capsule(4, 2_500_000, 2).unwrap();
        folder.save(&g3).unwrap();
        folder.save(&g4).unwrap();
        flip(&dir.path.join("capsule.b"), 100);
        assert_eq!(folder.newest().unwrap(), g3);
        // The next save goes over the damaged slot.
        folder.save(&g4).unwrap();
        assert_eq!(folder.newest().unwrap(), g4);
        flip(&dir.path.join("capsule.a"), 100);
        flip(&dir.path.join("capsule.b"), 100);
        assert_eq!(folder.newest(), Err(StoreError::BothUnreadable(RecordName::Capsule)));
        // A save after both are damaged is a repair, into slot A.
        folder.save(&g4).unwrap();
        assert_eq!(folder.newest().unwrap(), g4);
    }
}
