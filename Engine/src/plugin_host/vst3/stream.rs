#![allow(non_upper_case_globals)]

//! `MemoryStream`: an `IBStream` over a `Vec<u8>`, for `IComponent::getState`/`setState` and
//! `IEditController` state. The engine packs both VST3 state streams into one blob (spec 028
//! decisions); the blob helpers themselves live in the phase 2 command layer.

use std::cell::RefCell;
use std::ffi::c_void;
use std::ptr::copy_nonoverlapping;

use ::vst3::Class;
use ::vst3::Steinberg::IBStream_::IStreamSeekMode_::{kIBSeekCur, kIBSeekEnd, kIBSeekSet};
use ::vst3::Steinberg::{
    int32, int64, kInvalidArgument, kResultOk, tresult, IBStream, IBStreamTrait,
};

struct StreamData {
    bytes: Vec<u8>,
    pos: usize,
}

pub struct MemoryStream {
    data: RefCell<StreamData>,
}

impl MemoryStream {
    /// A stream over existing bytes, positioned at the start (for `setState`).
    pub fn with_bytes(bytes: Vec<u8>) -> Self {
        Self {
            data: RefCell::new(StreamData { bytes, pos: 0 }),
        }
    }

    /// An empty stream for writing (for `getState`).
    pub fn empty() -> Self {
        Self::with_bytes(Vec::new())
    }

    /// Take the written bytes out of the stream.
    pub fn into_bytes(self) -> Vec<u8> {
        self.data.into_inner().bytes
    }
}

impl Class for MemoryStream {
    type Interfaces = (IBStream,);
}

impl IBStreamTrait for MemoryStream {
    unsafe fn read(
        &self,
        buffer: *mut c_void,
        num_bytes: int32,
        num_bytes_read: *mut int32,
    ) -> tresult {
        if num_bytes < 0 {
            return kInvalidArgument;
        }
        let mut data = self.data.borrow_mut();
        let want = num_bytes as usize;
        let available = data.bytes.len().saturating_sub(data.pos);
        let count = want.min(available);
        if count > 0 {
            copy_nonoverlapping(data.bytes.as_ptr().add(data.pos), buffer as *mut u8, count);
        }
        data.pos += count;
        if !num_bytes_read.is_null() {
            *num_bytes_read = count as int32;
        }
        kResultOk
    }

    unsafe fn write(
        &self,
        buffer: *mut c_void,
        num_bytes: int32,
        num_bytes_written: *mut int32,
    ) -> tresult {
        if num_bytes < 0 || (buffer.is_null() && num_bytes > 0) {
            return kInvalidArgument;
        }
        let mut data = self.data.borrow_mut();
        let count = num_bytes as usize;
        // Writing past the end (after a seek) pads the gap, like a file would.
        if data.pos > data.bytes.len() {
            let pos = data.pos;
            data.bytes.resize(pos, 0);
        }
        data.bytes
            .extend_from_slice(std::slice::from_raw_parts(buffer as *const u8, count));
        data.pos += count;
        if !num_bytes_written.is_null() {
            *num_bytes_written = count as int32;
        }
        kResultOk
    }

    unsafe fn seek(&self, pos: int64, mode: int32, result: *mut int64) -> tresult {
        let mut data = self.data.borrow_mut();
        let target = match mode as u32 {
            kIBSeekSet => Some(pos),
            kIBSeekCur => pos
                .checked_add_unsigned(data.pos as u64)
                .and_then(|v| i64::try_from(v).ok()),
            kIBSeekEnd => pos
                .checked_add_unsigned(data.bytes.len() as u64)
                .and_then(|v| i64::try_from(v).ok()),
            _ => return kInvalidArgument,
        };
        let Some(target) = target else {
            return kInvalidArgument;
        };
        // Negative positions clamp to the start, as Steinberg's own stream implementations do.
        data.pos = target.max(0) as usize;
        if !result.is_null() {
            *result = data.pos as int64;
        }
        kResultOk
    }

    unsafe fn tell(&self, pos: *mut int64) -> tresult {
        if pos.is_null() {
            return kInvalidArgument;
        }
        *pos = self.data.borrow().pos as int64;
        kResultOk
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ::vst3::ComWrapper;
    use ::vst3::Steinberg::IBStream_::IStreamSeekMode_::{kIBSeekCur, kIBSeekEnd, kIBSeekSet};

    fn stream(bytes: Vec<u8>) -> (ComWrapper<MemoryStream>, ::vst3::ComPtr<IBStream>) {
        let wrapper = ComWrapper::new(MemoryStream::with_bytes(bytes));
        let ptr = wrapper.to_com_ptr::<IBStream>().unwrap();
        (wrapper, ptr)
    }

    #[test]
    fn read_returns_bytes_and_short_at_end() {
        let (_w, s) = stream(b"hello".to_vec());
        let mut buffer = [0u8; 8];
        let mut read = -1;
        assert_eq!(
            unsafe { s.read(buffer.as_mut_ptr() as *mut _, 3, &mut read) },
            0
        );
        assert_eq!(read, 3);
        assert_eq!(&buffer[..3], b"hel");
        // Reading past the end returns what's left.
        assert_eq!(
            unsafe { s.read(buffer.as_mut_ptr() as *mut _, 8, &mut read) },
            0
        );
        assert_eq!(read, 2);
        assert_eq!(&buffer[..2], b"lo");
        // And then nothing at all.
        assert_eq!(
            unsafe { s.read(buffer.as_mut_ptr() as *mut _, 8, &mut read) },
            0
        );
        assert_eq!(read, 0);
    }

    #[test]
    fn write_appends_and_reports_count() {
        let (_w, s) = stream(Vec::new());
        let mut written = -1;
        assert_eq!(
            unsafe { s.write(b"abc".as_ptr() as *mut _, 3, &mut written) },
            0
        );
        assert_eq!(written, 3);
        assert_eq!(
            unsafe { s.write(b"def".as_ptr() as *mut _, 3, &mut written) },
            0
        );
        assert_eq!(written, 3);
    }

    #[test]
    fn seek_and_tell_round_trip() {
        let (w, s) = stream(b"0123456789".to_vec());
        let mut pos = -1i64;
        assert_eq!(unsafe { s.seek(4, kIBSeekSet as i32, &mut pos) }, 0);
        assert_eq!(pos, 4);
        assert_eq!(unsafe { s.tell(&mut pos) }, 0);
        assert_eq!(pos, 4);

        assert_eq!(unsafe { s.seek(-2, kIBSeekCur as i32, &mut pos) }, 0);
        assert_eq!(unsafe { s.tell(&mut pos) }, 0);
        assert_eq!(pos, 2);

        assert_eq!(unsafe { s.seek(0, kIBSeekEnd as i32, &mut pos) }, 0);
        assert_eq!(pos, 10);

        // Clamps at the start instead of failing.
        assert_eq!(unsafe { s.seek(-100, kIBSeekCur as i32, &mut pos) }, 0);
        assert_eq!(pos, 0);

        assert_eq!(w.data.borrow().pos, 0);
    }

    #[test]
    fn write_after_seek_pads_the_gap() {
        let (w, s) = stream(Vec::new());
        let mut pos = -1i64;
        unsafe {
            assert_eq!(s.seek(3, kIBSeekSet as i32, &mut pos), 0);
            let mut written = -1;
            assert_eq!(s.write(b"xy".as_ptr() as *mut _, 2, &mut written), 0);
        }
        assert_eq!(w.data.borrow().bytes, b"\0\0\0xy");
    }

    #[test]
    fn bad_seek_mode_is_an_error() {
        let (_w, s) = stream(Vec::new());
        let mut pos = -1i64;
        assert_eq!(unsafe { s.seek(0, 99, &mut pos) }, kInvalidArgument);
    }
}
