//! Platform-specific shared memory implementation
//!
//! Provides real inter-process shared memory using:
//! - Linux: memfd_create() + mmap()
//! - macOS: shm_open() + mmap() (TODO)
//! - Windows: CreateFileMapping() (TODO)

use std::os::unix::io::{AsRawFd, RawFd, BorrowedFd, OwnedFd, FromRawFd};
use nix::sys::mman::{mmap, munmap, MapFlags, ProtFlags};
use nix::unistd::ftruncate;
use tracing::{error, info};

/// Platform-specific shared memory region
pub struct PlatformSharedMemory {
    // Use OwnedFd - the SINGLE owner of this file descriptor
    // Drop will close it automatically and safely
    fd: OwnedFd,
    ptr: *mut u8,
    size: usize,
}

impl PlatformSharedMemory {
    /// Create a new shared memory region using memfd_create (Linux)
    /// The FD can be passed to subprocesses via SCM_RIGHTS
    #[cfg(target_os = "linux")]
    pub fn new(name: &str, size: usize) -> Result<Self, String> {
        use std::ffi::CString;
        
        info!("Creating shared memory region: {} ({} bytes)", name, size);
        
        // Create anonymous file descriptor (memfd_create)
        let name_cstr = CString::new(name)
            .map_err(|e| format!("Invalid name: {}", e))?;
        
        let raw_fd = unsafe {
            libc::memfd_create(
                name_cstr.as_ptr(),
                libc::MFD_CLOEXEC | libc::MFD_ALLOW_SEALING,
            )
        };
        
        if raw_fd < 0 {
            return Err(format!("memfd_create failed: {}", 
                std::io::Error::last_os_error()));
        }
        
        // Wrap in OwnedFd - this is now the SINGLE owner
        let fd = unsafe { OwnedFd::from_raw_fd(raw_fd) };
        info!("🔍 Created OwnedFd for FD {} from memfd_create", fd.as_raw_fd());
        
        // Set size (borrow the fd for syscall)
        ftruncate(&fd, size as i64)
            .map_err(|e| format!("ftruncate failed: {}", e))?;
        
        // Map memory (borrow the fd for syscall)
        let ptr_nonnull = unsafe {
            mmap(
                None,
                std::num::NonZeroUsize::new(size).unwrap(),
                ProtFlags::PROT_READ | ProtFlags::PROT_WRITE,
                MapFlags::MAP_SHARED,
                &fd,
                0,
            ).map_err(|e| format!("mmap failed: {}", e))?
        };
        
        let ptr = ptr_nonnull.as_ptr() as *mut u8;
        info!("Shared memory mapped at {:?}", ptr);
        
        Ok(Self {
            fd,
            ptr,
            size,
        })
    }
    
    /// Map existing shared memory from file descriptor
    /// Takes ownership of the FD (caller must ensure FD is valid and won't be closed elsewhere)
    #[cfg(target_os = "linux")]
    pub fn from_fd(fd: RawFd, size: usize) -> Result<Self, String> {
        info!("🗺️  Mapping shared memory from fd={} ({} bytes)", fd, size);
        
        // Wrap in OwnedFd - this is now the SINGLE owner
        let owned_fd = unsafe { OwnedFd::from_raw_fd(fd) };
        let fd_after_wrap = owned_fd.as_raw_fd();
        
        info!("   📍 Input FD={}, OwnedFd.as_raw_fd()={}", fd, fd_after_wrap);
        info!("   Calling mmap on FD {}", fd_after_wrap);
        let ptr_nonnull = unsafe {
            mmap(
                None,
                std::num::NonZeroUsize::new(size).unwrap(),
                ProtFlags::PROT_READ | ProtFlags::PROT_WRITE,
                MapFlags::MAP_SHARED,
                &owned_fd,
                0,
            ).map_err(|e| format!("mmap failed: {}", e))?
        };
        
        let ptr = ptr_nonnull.as_ptr() as *mut u8;
        let fd_after_mmap = owned_fd.as_raw_fd();
        info!("✅ Shared memory mapped at {:?}, OwnedFd.as_raw_fd()={}", ptr, fd_after_mmap);
        
        Ok(Self {
            fd: owned_fd,
            ptr,
            size,
        })
    }
    
    /// Get raw file descriptor (for passing to subprocess via SCM_RIGHTS)
    /// This borrows the FD - we remain the owner
    pub fn as_raw_fd(&self) -> RawFd {
        self.fd.as_raw_fd()
    }
    
    /// Get raw memory pointer
    pub fn as_ptr(&self) -> *const u8 {
        self.ptr
    }
    
    /// Get mutable raw memory pointer
    pub fn as_mut_ptr(&mut self) -> *mut u8 {
        self.ptr
    }
    
    /// Get size in bytes
    pub fn size(&self) -> usize {
        self.size
    }
    
    /// Get memory as slice
    pub fn as_slice(&self) -> &[u8] {
        unsafe { std::slice::from_raw_parts(self.ptr, self.size) }
    }
    
    /// Get memory as mutable slice
    pub fn as_mut_slice(&mut self) -> &mut [u8] {
        unsafe { std::slice::from_raw_parts_mut(self.ptr, self.size) }
    }
}

impl Drop for PlatformSharedMemory {
    fn drop(&mut self) {
        let fd_num = self.fd.as_raw_fd();
        info!("🔍 Dropping PlatformSharedMemory with FD {}", fd_num);
        
        // Unmap memory first
        if let Err(e) = unsafe {
            let ptr = std::ptr::NonNull::new_unchecked(self.ptr as *mut std::ffi::c_void);
            munmap(ptr, self.size)
        } {
            error!("Failed to munmap: {}", e);
        }
        
        // OwnedFd will automatically close the FD when it drops
        // No manual close needed - this is the correct pattern!
        info!("✅ About to drop OwnedFd for FD {} (this will close it)", fd_num);
        // Drop happens here when function ends
    }
}

// Not Send/Sync by default since we're dealing with raw pointers
// This is intentional - shared memory access must be carefully synchronized
unsafe impl Send for PlatformSharedMemory {}
unsafe impl Sync for PlatformSharedMemory {}

#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn test_create_shared_memory() {
        let mut shm = PlatformSharedMemory::new("test_shm", 4096).unwrap();
        
        // Write some data
        let slice = shm.as_mut_slice();
        slice[0] = 42;
        slice[100] = 255;
        
        // Read it back
        let read_slice = shm.as_slice();
        assert_eq!(read_slice[0], 42);
        assert_eq!(read_slice[100], 255);
    }
    
    #[test]
    fn test_fd_passing_simulation() {
        // Create shared memory
        let mut shm1 = PlatformSharedMemory::new("test_fd_pass", 1024).unwrap();
        
        // Write data
        shm1.as_mut_slice()[0] = 123;
        
        // Simulate passing FD to another process (duplicate FD)
        let fd = shm1.as_raw_fd();
        let dup_fd = unsafe { libc::dup(fd) };
        assert!(dup_fd >= 0);
        
        // Map in "another process" (same process for test)
        let shm2 = PlatformSharedMemory::from_fd(dup_fd, 1024).unwrap();
        
        // Read data from second mapping
        assert_eq!(shm2.as_slice()[0], 123);
        
        // Modify via second mapping
        let slice2 = unsafe { std::slice::from_raw_parts_mut(shm2.ptr, shm2.size) };
        slice2[1] = 200;
        
        // Verify visible in first mapping
        assert_eq!(shm1.as_slice()[1], 200);
    }
}

