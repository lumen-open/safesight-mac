// SPDX-License-Identifier: Apache-2.0
//! The common frame of every keeper record (SD-022; register 8a; chapter 02 table 8b).
//!
//! Every record is: magic, record type, format version, length, fields, checksum. There
//! is exactly one valid byte string for a record value. A decoder is a total function
//! from a byte slice to "record or refuse": it never panics and never guesses.
//!
//! The register fixes the order of the parts. It does not fix their widths, the byte
//! order, the magic value or the checksum algorithm (chapter 02, point N1). The values
//! below are chapter 02's proposal where it makes one, and are marked OPEN.

/// The fixed product tag at the start of every record.
// OPEN: SD-022 / N1 - the magic value is not specified. Working value "SSMK".
pub const MAGIC: [u8; 4] = [0x53, 0x53, 0x4d, 0x4b];

/// Magic (4), record type (2), format version (2), length (4).
// OPEN: SD-022 / N1 - widths and byte order are chapter 02's proposal (table 8b):
// unsigned little-endian integers.
pub const HEADER_LEN: usize = 12;

/// The checksum covers every byte before it.
// OPEN: SD-022 / N1 - the checksum algorithm and width are not specified. Working value:
// CRC-32 (the IEEE polynomial, reflected), 4 bytes, little-endian. It guards against a
// torn or damaged write, which is all the register asks of it. It is not a signature.
pub const CHECKSUM_LEN: usize = 4;

/// Bytes every record spends on the frame.
pub const FRAME_OVERHEAD: usize = HEADER_LEN + CHECKSUM_LEN;

/// Why a byte string was refused. A refusal changes nothing and blames nobody.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecordError {
    /// Shorter than any framed record.
    TooShort,
    /// The first four bytes are not the product tag.
    BadMagic,
    /// A record of another type.
    WrongType,
    /// A format version this keeper does not know: "update needed" (register 6e).
    UpdateNeeded,
    /// Not the one length this type and version allow.
    WrongLength,
    /// The checksum does not match the bytes before it.
    BadChecksum,
    /// A field holds a value outside its set or range, or two fields disagree.
    InvalidField,
    /// A padding byte, or the value slot of an absent field, is not zero.
    NonZeroPadding,
    /// The fields end before the checksum begins. A decoder bug, never accepted.
    TrailingBytes,
}

/// CRC-32 as used by zip and PNG: polynomial 0xEDB88320, initial value and final
/// inversion all ones. Bit by bit, with no table, so there is nothing to get wrong.
pub fn crc32(data: &[u8]) -> u32 {
    let mut crc: u32 = 0xFFFF_FFFF;
    for byte in data.iter() {
        crc ^= *byte as u32;
        let mut bit = 0;
        while bit < 8 {
            if crc & 1 == 1 {
                crc = (crc >> 1) ^ 0xEDB8_8320;
            } else {
                crc >>= 1;
            }
            bit += 1;
        }
    }
    !crc
}

/// Builds one framed record.
pub struct Writer {
    buf: Vec<u8>,
    total_len: usize,
}

impl Writer {
    /// Starts a record of `total_len` bytes, frame and checksum included.
    pub fn begin(record_type: u16, version: u16, total_len: usize) -> Writer {
        let mut buf: Vec<u8> = Vec::with_capacity(total_len);
        buf.extend_from_slice(&MAGIC);
        buf.extend_from_slice(&record_type.to_le_bytes());
        buf.extend_from_slice(&version.to_le_bytes());
        buf.extend_from_slice(&(total_len as u32).to_le_bytes());
        Writer { buf, total_len }
    }

    pub fn put_u8(&mut self, value: u8) {
        self.buf.push(value);
    }

    pub fn put_u16(&mut self, value: u16) {
        self.buf.extend_from_slice(&value.to_le_bytes());
    }

    pub fn put_u64(&mut self, value: u64) {
        self.buf.extend_from_slice(&value.to_le_bytes());
    }

    pub fn put_bytes(&mut self, bytes: &[u8]) {
        self.buf.extend_from_slice(bytes);
    }

    pub fn put_zeros(&mut self, count: usize) {
        let new_len = self.buf.len() + count;
        self.buf.resize(new_len, 0);
    }

    /// One byte: 1 for yes, 0 for no.
    pub fn put_flag(&mut self, value: bool) {
        if value {
            self.buf.push(1);
        } else {
            self.buf.push(0);
        }
    }

    /// "A value, or none": a flag byte, then eight bytes that are zero when there is none.
    pub fn put_opt_u64(&mut self, value: Option<u64>) {
        match value {
            Some(v) => {
                self.put_flag(true);
                self.put_u64(v);
            }
            None => {
                self.put_flag(false);
                self.put_u64(0);
            }
        }
    }

    /// Appends the checksum. Refuses if the fields did not fill the record exactly.
    pub fn finish(self) -> Result<Vec<u8>, RecordError> {
        let mut buf = self.buf;
        if buf.len() + CHECKSUM_LEN != self.total_len {
            return Err(RecordError::WrongLength);
        }
        let sum = crc32(&buf);
        buf.extend_from_slice(&sum.to_le_bytes());
        Ok(buf)
    }
}

/// Reads one framed record. `open` does every frame check before a field is read.
pub struct Reader<'a> {
    bytes: &'a [u8],
    pos: usize,
    end: usize,
}

impl<'a> Reader<'a> {
    /// Checks, in order: a whole frame is present; magic; record type; format version
    /// (any other version is "update needed"); the exact length for this type and
    /// version, in the slice and in the length field; the checksum.
    pub fn open(
        bytes: &'a [u8],
        record_type: u16,
        version: u16,
        total_len: usize,
    ) -> Result<Reader<'a>, RecordError> {
        if total_len < FRAME_OVERHEAD {
            return Err(RecordError::WrongLength);
        }
        if bytes.len() < FRAME_OVERHEAD {
            return Err(RecordError::TooShort);
        }
        if bytes[0] != MAGIC[0] || bytes[1] != MAGIC[1] || bytes[2] != MAGIC[2] || bytes[3] != MAGIC[3] {
            return Err(RecordError::BadMagic);
        }
        let found_type = u16::from_le_bytes([bytes[4], bytes[5]]);
        if found_type != record_type {
            return Err(RecordError::WrongType);
        }
        let found_version = u16::from_le_bytes([bytes[6], bytes[7]]);
        if found_version != version {
            return Err(RecordError::UpdateNeeded);
        }
        let found_len = u32::from_le_bytes([bytes[8], bytes[9], bytes[10], bytes[11]]) as usize;
        if found_len != total_len || bytes.len() != total_len {
            return Err(RecordError::WrongLength);
        }
        let body_end = total_len - CHECKSUM_LEN;
        let stored = u32::from_le_bytes([
            bytes[body_end],
            bytes[body_end + 1],
            bytes[body_end + 2],
            bytes[body_end + 3],
        ]);
        if crc32(&bytes[..body_end]) != stored {
            return Err(RecordError::BadChecksum);
        }
        Ok(Reader { bytes, pos: HEADER_LEN, end: body_end })
    }

    /// The next `count` bytes of the fields.
    pub fn take(&mut self, count: usize) -> Result<&'a [u8], RecordError> {
        let all: &'a [u8] = self.bytes;
        let stop = match self.pos.checked_add(count) {
            Some(s) => s,
            None => return Err(RecordError::WrongLength),
        };
        if stop > self.end {
            return Err(RecordError::WrongLength);
        }
        let out = &all[self.pos..stop];
        self.pos = stop;
        Ok(out)
    }

    pub fn read_u8(&mut self) -> Result<u8, RecordError> {
        let b = self.take(1)?;
        Ok(b[0])
    }

    pub fn read_u16(&mut self) -> Result<u16, RecordError> {
        let b = self.take(2)?;
        Ok(u16::from_le_bytes([b[0], b[1]]))
    }

    pub fn read_u64(&mut self) -> Result<u64, RecordError> {
        let b = self.take(8)?;
        Ok(u64::from_le_bytes([b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]]))
    }

    /// One byte that must be 0 or 1.
    pub fn read_flag(&mut self) -> Result<bool, RecordError> {
        match self.read_u8()? {
            0 => Ok(false),
            1 => Ok(true),
            _ => Err(RecordError::InvalidField),
        }
    }

    /// "A value, or none". With no value the eight bytes must be zero.
    pub fn read_opt_u64(&mut self) -> Result<Option<u64>, RecordError> {
        let present = self.read_flag()?;
        let value = self.read_u64()?;
        if present {
            Ok(Some(value))
        } else if value == 0 {
            Ok(None)
        } else {
            Err(RecordError::NonZeroPadding)
        }
    }

    /// `count` bytes that must all be zero.
    pub fn read_zeros(&mut self, count: usize) -> Result<(), RecordError> {
        let b = self.take(count)?;
        for byte in b.iter() {
            if *byte != 0 {
                return Err(RecordError::NonZeroPadding);
            }
        }
        Ok(())
    }

    /// Every field byte must have been read.
    pub fn close(self) -> Result<(), RecordError> {
        if self.pos == self.end {
            Ok(())
        } else {
            Err(RecordError::TrailingBytes)
        }
    }
}

/// Test help: recompute the checksum after a test has changed a byte on purpose, so the
/// field checks behind the checksum can be reached.
#[cfg(test)]
pub(crate) fn reseal(bytes: &mut [u8]) {
    let n = bytes.len();
    if n < CHECKSUM_LEN {
        return;
    }
    let sum = crc32(&bytes[..n - CHECKSUM_LEN]);
    let sum_bytes = sum.to_le_bytes();
    bytes[n - 4] = sum_bytes[0];
    bytes[n - 3] = sum_bytes[1];
    bytes[n - 2] = sum_bytes[2];
    bytes[n - 1] = sum_bytes[3];
}

#[cfg(test)]
mod tests {
    use super::*;

    const TEST_TYPE: u16 = 900;
    const TEST_LEN: usize = FRAME_OVERHEAD + 1 + 2 + 8 + 9 + 9 + 1 + 3;

    fn sample() -> Vec<u8> {
        let mut w = Writer::begin(TEST_TYPE, 1, TEST_LEN);
        w.put_u8(7);
        w.put_u16(0x1234);
        w.put_u64(0x0102_0304_0506_0708);
        w.put_opt_u64(Some(99));
        w.put_opt_u64(None);
        w.put_flag(true);
        w.put_zeros(3);
        w.finish().unwrap()
    }

    #[test]
    fn crc32_matches_the_published_check_values() {
        assert_eq!(crc32(b""), 0);
        assert_eq!(crc32(b"123456789"), 0xCBF4_3926);
        assert_eq!(crc32(b"a"), 0xE8B7_BE43);
    }

    #[test]
    fn the_frame_is_laid_out_as_documented() {
        let bytes = sample();
        assert_eq!(bytes.len(), TEST_LEN);
        assert_eq!(&bytes[0..4], &MAGIC[..]);
        assert_eq!(&bytes[0..4], &b"SSMK"[..]);
        assert_eq!(&bytes[4..6], &[0x84u8, 0x03][..]);
        assert_eq!(&bytes[6..8], &[1u8, 0][..]);
        assert_eq!(&bytes[8..12], &[TEST_LEN as u8, 0, 0, 0][..]);
        assert_eq!(bytes[12], 7);
        assert_eq!(&bytes[13..15], &[0x34u8, 0x12][..]);
        assert_eq!(&bytes[15..23], &[8u8, 7, 6, 5, 4, 3, 2, 1][..]);
        let sum = crc32(&bytes[..TEST_LEN - 4]).to_le_bytes();
        assert_eq!(&bytes[TEST_LEN - 4..], &sum[..]);
    }

    #[test]
    fn a_written_record_reads_back() {
        let bytes = sample();
        let mut r = Reader::open(&bytes, TEST_TYPE, 1, TEST_LEN).unwrap();
        assert_eq!(r.read_u8().unwrap(), 7);
        assert_eq!(r.read_u16().unwrap(), 0x1234);
        assert_eq!(r.read_u64().unwrap(), 0x0102_0304_0506_0708);
        assert_eq!(r.read_opt_u64().unwrap(), Some(99));
        assert_eq!(r.read_opt_u64().unwrap(), None);
        assert_eq!(r.read_flag().unwrap(), true);
        r.read_zeros(3).unwrap();
        r.close().unwrap();
    }

    #[test]
    fn the_writer_refuses_a_record_that_is_not_filled_exactly() {
        let mut short = Writer::begin(TEST_TYPE, 1, TEST_LEN);
        short.put_u8(1);
        assert_eq!(short.finish(), Err(RecordError::WrongLength));
        let mut long = Writer::begin(TEST_TYPE, 1, FRAME_OVERHEAD);
        long.put_u8(1);
        assert_eq!(long.finish(), Err(RecordError::WrongLength));
    }

    fn open_error(bytes: &[u8]) -> Option<RecordError> {
        match Reader::open(bytes, TEST_TYPE, 1, TEST_LEN) {
            Ok(_) => None,
            Err(e) => Some(e),
        }
    }

    #[test]
    fn open_refuses_every_frame_fault() {
        let good = sample();
        assert_eq!(open_error(&good), None);
        assert_eq!(open_error(&[]), Some(RecordError::TooShort));
        assert_eq!(open_error(&good[..15]), Some(RecordError::TooShort));
        assert_eq!(open_error(&good[..TEST_LEN - 1]), Some(RecordError::WrongLength));

        let mut longer = good.clone();
        longer.push(0);
        assert_eq!(open_error(&longer), Some(RecordError::WrongLength));

        let mut magic = good.clone();
        magic[3] = 0x4c;
        assert_eq!(open_error(&magic), Some(RecordError::BadMagic));

        let mut other_type = good.clone();
        other_type[4] = 0x85;
        reseal(&mut other_type);
        assert_eq!(open_error(&other_type), Some(RecordError::WrongType));

        let mut version_two = good.clone();
        version_two[6] = 2;
        reseal(&mut version_two);
        assert_eq!(open_error(&version_two), Some(RecordError::UpdateNeeded));

        let mut version_zero = good.clone();
        version_zero[6] = 0;
        reseal(&mut version_zero);
        assert_eq!(open_error(&version_zero), Some(RecordError::UpdateNeeded));

        let mut length_field = good.clone();
        length_field[8] = (TEST_LEN as u8) + 1;
        reseal(&mut length_field);
        assert_eq!(open_error(&length_field), Some(RecordError::WrongLength));

        let mut checksum = good.clone();
        checksum[TEST_LEN - 1] ^= 0x01;
        assert_eq!(open_error(&checksum), Some(RecordError::BadChecksum));

        let mut body = good.clone();
        body[13] ^= 0x80;
        assert_eq!(open_error(&body), Some(RecordError::BadChecksum));
    }

    #[test]
    fn open_refuses_a_record_length_smaller_than_the_frame() {
        let good = sample();
        match Reader::open(&good, TEST_TYPE, 1, 8) {
            Ok(_) => panic!("accepted"),
            Err(e) => assert_eq!(e, RecordError::WrongLength),
        }
    }

    #[test]
    fn field_reads_refuse_bad_values_and_never_run_past_the_fields() {
        // A flag byte that is neither 0 nor 1.
        let mut w = Writer::begin(TEST_TYPE, 1, FRAME_OVERHEAD + 1);
        w.put_u8(2);
        let bytes = w.finish().unwrap();
        let mut r = Reader::open(&bytes, TEST_TYPE, 1, FRAME_OVERHEAD + 1).unwrap();
        assert_eq!(r.read_flag(), Err(RecordError::InvalidField));

        // "None" with a non-zero value slot.
        let mut w = Writer::begin(TEST_TYPE, 1, FRAME_OVERHEAD + 9);
        w.put_u8(0);
        w.put_u64(5);
        let bytes = w.finish().unwrap();
        let mut r = Reader::open(&bytes, TEST_TYPE, 1, FRAME_OVERHEAD + 9).unwrap();
        assert_eq!(r.read_opt_u64(), Err(RecordError::NonZeroPadding));

        // Padding that is not zero.
        let mut w = Writer::begin(TEST_TYPE, 1, FRAME_OVERHEAD + 2);
        w.put_u8(0);
        w.put_u8(1);
        let bytes = w.finish().unwrap();
        let mut r = Reader::open(&bytes, TEST_TYPE, 1, FRAME_OVERHEAD + 2).unwrap();
        assert_eq!(r.read_zeros(2), Err(RecordError::NonZeroPadding));

        // Reading past the fields, and leaving fields unread.
        let mut w = Writer::begin(TEST_TYPE, 1, FRAME_OVERHEAD + 2);
        w.put_u16(1);
        let bytes = w.finish().unwrap();
        let mut r = Reader::open(&bytes, TEST_TYPE, 1, FRAME_OVERHEAD + 2).unwrap();
        assert_eq!(r.read_u64(), Err(RecordError::WrongLength));
        let r = Reader::open(&bytes, TEST_TYPE, 1, FRAME_OVERHEAD + 2).unwrap();
        assert_eq!(r.close(), Err(RecordError::TrailingBytes));
    }
}
