// Generated from the pinned engine WASI imports by prepare_notebook_typesetter.py.
use super::NativeState;
use std::{future::Future, pin::pin, task::{Context, Poll, Waker}};
use wasi_common::snapshots::preview_1::wasi_snapshot_preview1 as wasi;
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nb_wasi_args_get(state: *mut NativeState, bytes: *mut u8, len: usize, a0: u32, a1: u32) -> u32 {
  let state = unsafe { &mut *state };
  if state.check() { return u32::MAX; }
  let mut memory = wiggle::GuestMemory::Unshared(unsafe { std::slice::from_raw_parts_mut(bytes, len) });
  let future = wasi::args_get(&mut state.wasi, &mut memory, a0 as i32, a1 as i32);
  match pin!(future).poll(&mut Context::from_waker(Waker::noop())) {
    Poll::Ready(Ok(result)) => result as u32,
    Poll::Ready(Err(error)) => { state.failure = Some(error.to_string()); u32::MAX },
    Poll::Pending => { state.failure = Some("Blocking WASI operation denied".into()); u32::MAX },
  }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nb_wasi_args_sizes_get(state: *mut NativeState, bytes: *mut u8, len: usize, a0: u32, a1: u32) -> u32 {
  let state = unsafe { &mut *state };
  if state.check() { return u32::MAX; }
  let mut memory = wiggle::GuestMemory::Unshared(unsafe { std::slice::from_raw_parts_mut(bytes, len) });
  let future = wasi::args_sizes_get(&mut state.wasi, &mut memory, a0 as i32, a1 as i32);
  match pin!(future).poll(&mut Context::from_waker(Waker::noop())) {
    Poll::Ready(Ok(result)) => result as u32,
    Poll::Ready(Err(error)) => { state.failure = Some(error.to_string()); u32::MAX },
    Poll::Pending => { state.failure = Some("Blocking WASI operation denied".into()); u32::MAX },
  }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nb_wasi_clock_time_get(state: *mut NativeState, bytes: *mut u8, len: usize, a0: u32, a1: u64, a2: u32) -> u32 {
  let state = unsafe { &mut *state };
  if state.check() { return u32::MAX; }
  let mut memory = wiggle::GuestMemory::Unshared(unsafe { std::slice::from_raw_parts_mut(bytes, len) });
  let future = wasi::clock_time_get(&mut state.wasi, &mut memory, a0 as i32, a1 as i64, a2 as i32);
  match pin!(future).poll(&mut Context::from_waker(Waker::noop())) {
    Poll::Ready(Ok(result)) => result as u32,
    Poll::Ready(Err(error)) => { state.failure = Some(error.to_string()); u32::MAX },
    Poll::Pending => { state.failure = Some("Blocking WASI operation denied".into()); u32::MAX },
  }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nb_wasi_environ_get(state: *mut NativeState, bytes: *mut u8, len: usize, a0: u32, a1: u32) -> u32 {
  let state = unsafe { &mut *state };
  if state.check() { return u32::MAX; }
  let mut memory = wiggle::GuestMemory::Unshared(unsafe { std::slice::from_raw_parts_mut(bytes, len) });
  let future = wasi::environ_get(&mut state.wasi, &mut memory, a0 as i32, a1 as i32);
  match pin!(future).poll(&mut Context::from_waker(Waker::noop())) {
    Poll::Ready(Ok(result)) => result as u32,
    Poll::Ready(Err(error)) => { state.failure = Some(error.to_string()); u32::MAX },
    Poll::Pending => { state.failure = Some("Blocking WASI operation denied".into()); u32::MAX },
  }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nb_wasi_environ_sizes_get(state: *mut NativeState, bytes: *mut u8, len: usize, a0: u32, a1: u32) -> u32 {
  let state = unsafe { &mut *state };
  if state.check() { return u32::MAX; }
  let mut memory = wiggle::GuestMemory::Unshared(unsafe { std::slice::from_raw_parts_mut(bytes, len) });
  let future = wasi::environ_sizes_get(&mut state.wasi, &mut memory, a0 as i32, a1 as i32);
  match pin!(future).poll(&mut Context::from_waker(Waker::noop())) {
    Poll::Ready(Ok(result)) => result as u32,
    Poll::Ready(Err(error)) => { state.failure = Some(error.to_string()); u32::MAX },
    Poll::Pending => { state.failure = Some("Blocking WASI operation denied".into()); u32::MAX },
  }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nb_wasi_fd_close(state: *mut NativeState, bytes: *mut u8, len: usize, a0: u32) -> u32 {
  let state = unsafe { &mut *state };
  if state.check() { return u32::MAX; }
  let mut memory = wiggle::GuestMemory::Unshared(unsafe { std::slice::from_raw_parts_mut(bytes, len) });
  let future = wasi::fd_close(&mut state.wasi, &mut memory, a0 as i32);
  match pin!(future).poll(&mut Context::from_waker(Waker::noop())) {
    Poll::Ready(Ok(result)) => result as u32,
    Poll::Ready(Err(error)) => { state.failure = Some(error.to_string()); u32::MAX },
    Poll::Pending => { state.failure = Some("Blocking WASI operation denied".into()); u32::MAX },
  }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nb_wasi_fd_fdstat_get(state: *mut NativeState, bytes: *mut u8, len: usize, a0: u32, a1: u32) -> u32 {
  let state = unsafe { &mut *state };
  if state.check() { return u32::MAX; }
  let mut memory = wiggle::GuestMemory::Unshared(unsafe { std::slice::from_raw_parts_mut(bytes, len) });
  let future = wasi::fd_fdstat_get(&mut state.wasi, &mut memory, a0 as i32, a1 as i32);
  match pin!(future).poll(&mut Context::from_waker(Waker::noop())) {
    Poll::Ready(Ok(result)) => result as u32,
    Poll::Ready(Err(error)) => { state.failure = Some(error.to_string()); u32::MAX },
    Poll::Pending => { state.failure = Some("Blocking WASI operation denied".into()); u32::MAX },
  }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nb_wasi_fd_fdstat_set_flags(state: *mut NativeState, bytes: *mut u8, len: usize, a0: u32, a1: u32) -> u32 {
  let state = unsafe { &mut *state };
  if state.check() { return u32::MAX; }
  let mut memory = wiggle::GuestMemory::Unshared(unsafe { std::slice::from_raw_parts_mut(bytes, len) });
  let future = wasi::fd_fdstat_set_flags(&mut state.wasi, &mut memory, a0 as i32, a1 as i32);
  match pin!(future).poll(&mut Context::from_waker(Waker::noop())) {
    Poll::Ready(Ok(result)) => result as u32,
    Poll::Ready(Err(error)) => { state.failure = Some(error.to_string()); u32::MAX },
    Poll::Pending => { state.failure = Some("Blocking WASI operation denied".into()); u32::MAX },
  }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nb_wasi_fd_filestat_get(state: *mut NativeState, bytes: *mut u8, len: usize, a0: u32, a1: u32) -> u32 {
  let state = unsafe { &mut *state };
  if state.check() { return u32::MAX; }
  let mut memory = wiggle::GuestMemory::Unshared(unsafe { std::slice::from_raw_parts_mut(bytes, len) });
  let future = wasi::fd_filestat_get(&mut state.wasi, &mut memory, a0 as i32, a1 as i32);
  match pin!(future).poll(&mut Context::from_waker(Waker::noop())) {
    Poll::Ready(Ok(result)) => result as u32,
    Poll::Ready(Err(error)) => { state.failure = Some(error.to_string()); u32::MAX },
    Poll::Pending => { state.failure = Some("Blocking WASI operation denied".into()); u32::MAX },
  }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nb_wasi_fd_pread(state: *mut NativeState, bytes: *mut u8, len: usize, a0: u32, a1: u32, a2: u32, a3: u64, a4: u32) -> u32 {
  let state = unsafe { &mut *state };
  if state.check() { return u32::MAX; }
  let mut memory = wiggle::GuestMemory::Unshared(unsafe { std::slice::from_raw_parts_mut(bytes, len) });
  let future = wasi::fd_pread(&mut state.wasi, &mut memory, a0 as i32, a1 as i32, a2 as i32, a3 as i64, a4 as i32);
  match pin!(future).poll(&mut Context::from_waker(Waker::noop())) {
    Poll::Ready(Ok(result)) => result as u32,
    Poll::Ready(Err(error)) => { state.failure = Some(error.to_string()); u32::MAX },
    Poll::Pending => { state.failure = Some("Blocking WASI operation denied".into()); u32::MAX },
  }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nb_wasi_fd_prestat_dir_name(state: *mut NativeState, bytes: *mut u8, len: usize, a0: u32, a1: u32, a2: u32) -> u32 {
  let state = unsafe { &mut *state };
  if state.check() { return u32::MAX; }
  let mut memory = wiggle::GuestMemory::Unshared(unsafe { std::slice::from_raw_parts_mut(bytes, len) });
  let future = wasi::fd_prestat_dir_name(&mut state.wasi, &mut memory, a0 as i32, a1 as i32, a2 as i32);
  match pin!(future).poll(&mut Context::from_waker(Waker::noop())) {
    Poll::Ready(Ok(result)) => result as u32,
    Poll::Ready(Err(error)) => { state.failure = Some(error.to_string()); u32::MAX },
    Poll::Pending => { state.failure = Some("Blocking WASI operation denied".into()); u32::MAX },
  }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nb_wasi_fd_prestat_get(state: *mut NativeState, bytes: *mut u8, len: usize, a0: u32, a1: u32) -> u32 {
  let state = unsafe { &mut *state };
  if state.check() { return u32::MAX; }
  let mut memory = wiggle::GuestMemory::Unshared(unsafe { std::slice::from_raw_parts_mut(bytes, len) });
  let future = wasi::fd_prestat_get(&mut state.wasi, &mut memory, a0 as i32, a1 as i32);
  match pin!(future).poll(&mut Context::from_waker(Waker::noop())) {
    Poll::Ready(Ok(result)) => result as u32,
    Poll::Ready(Err(error)) => { state.failure = Some(error.to_string()); u32::MAX },
    Poll::Pending => { state.failure = Some("Blocking WASI operation denied".into()); u32::MAX },
  }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nb_wasi_fd_read(state: *mut NativeState, bytes: *mut u8, len: usize, a0: u32, a1: u32, a2: u32, a3: u32) -> u32 {
  let state = unsafe { &mut *state };
  if state.check() { return u32::MAX; }
  let mut memory = wiggle::GuestMemory::Unshared(unsafe { std::slice::from_raw_parts_mut(bytes, len) });
  let future = wasi::fd_read(&mut state.wasi, &mut memory, a0 as i32, a1 as i32, a2 as i32, a3 as i32);
  match pin!(future).poll(&mut Context::from_waker(Waker::noop())) {
    Poll::Ready(Ok(result)) => result as u32,
    Poll::Ready(Err(error)) => { state.failure = Some(error.to_string()); u32::MAX },
    Poll::Pending => { state.failure = Some("Blocking WASI operation denied".into()); u32::MAX },
  }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nb_wasi_fd_readdir(state: *mut NativeState, bytes: *mut u8, len: usize, a0: u32, a1: u32, a2: u32, a3: u64, a4: u32) -> u32 {
  let state = unsafe { &mut *state };
  if state.check() { return u32::MAX; }
  let mut memory = wiggle::GuestMemory::Unshared(unsafe { std::slice::from_raw_parts_mut(bytes, len) });
  let future = wasi::fd_readdir(&mut state.wasi, &mut memory, a0 as i32, a1 as i32, a2 as i32, a3 as i64, a4 as i32);
  match pin!(future).poll(&mut Context::from_waker(Waker::noop())) {
    Poll::Ready(Ok(result)) => result as u32,
    Poll::Ready(Err(error)) => { state.failure = Some(error.to_string()); u32::MAX },
    Poll::Pending => { state.failure = Some("Blocking WASI operation denied".into()); u32::MAX },
  }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nb_wasi_fd_seek(state: *mut NativeState, bytes: *mut u8, len: usize, a0: u32, a1: u64, a2: u32, a3: u32) -> u32 {
  let state = unsafe { &mut *state };
  if state.check() { return u32::MAX; }
  let mut memory = wiggle::GuestMemory::Unshared(unsafe { std::slice::from_raw_parts_mut(bytes, len) });
  let future = wasi::fd_seek(&mut state.wasi, &mut memory, a0 as i32, a1 as i64, a2 as i32, a3 as i32);
  match pin!(future).poll(&mut Context::from_waker(Waker::noop())) {
    Poll::Ready(Ok(result)) => result as u32,
    Poll::Ready(Err(error)) => { state.failure = Some(error.to_string()); u32::MAX },
    Poll::Pending => { state.failure = Some("Blocking WASI operation denied".into()); u32::MAX },
  }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nb_wasi_fd_write(state: *mut NativeState, bytes: *mut u8, len: usize, a0: u32, a1: u32, a2: u32, a3: u32) -> u32 {
  let state = unsafe { &mut *state };
  if state.check() { return u32::MAX; }
  let mut memory = wiggle::GuestMemory::Unshared(unsafe { std::slice::from_raw_parts_mut(bytes, len) });
  let future = wasi::fd_write(&mut state.wasi, &mut memory, a0 as i32, a1 as i32, a2 as i32, a3 as i32);
  match pin!(future).poll(&mut Context::from_waker(Waker::noop())) {
    Poll::Ready(Ok(result)) => result as u32,
    Poll::Ready(Err(error)) => { state.failure = Some(error.to_string()); u32::MAX },
    Poll::Pending => { state.failure = Some("Blocking WASI operation denied".into()); u32::MAX },
  }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nb_wasi_path_create_directory(state: *mut NativeState, bytes: *mut u8, len: usize, a0: u32, a1: u32, a2: u32) -> u32 {
  let state = unsafe { &mut *state };
  if state.check() { return u32::MAX; }
  let mut memory = wiggle::GuestMemory::Unshared(unsafe { std::slice::from_raw_parts_mut(bytes, len) });
  let future = wasi::path_create_directory(&mut state.wasi, &mut memory, a0 as i32, a1 as i32, a2 as i32);
  match pin!(future).poll(&mut Context::from_waker(Waker::noop())) {
    Poll::Ready(Ok(result)) => result as u32,
    Poll::Ready(Err(error)) => { state.failure = Some(error.to_string()); u32::MAX },
    Poll::Pending => { state.failure = Some("Blocking WASI operation denied".into()); u32::MAX },
  }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nb_wasi_path_filestat_get(state: *mut NativeState, bytes: *mut u8, len: usize, a0: u32, a1: u32, a2: u32, a3: u32, a4: u32) -> u32 {
  let state = unsafe { &mut *state };
  if state.check() { return u32::MAX; }
  let mut memory = wiggle::GuestMemory::Unshared(unsafe { std::slice::from_raw_parts_mut(bytes, len) });
  let future = wasi::path_filestat_get(&mut state.wasi, &mut memory, a0 as i32, a1 as i32, a2 as i32, a3 as i32, a4 as i32);
  match pin!(future).poll(&mut Context::from_waker(Waker::noop())) {
    Poll::Ready(Ok(result)) => result as u32,
    Poll::Ready(Err(error)) => { state.failure = Some(error.to_string()); u32::MAX },
    Poll::Pending => { state.failure = Some("Blocking WASI operation denied".into()); u32::MAX },
  }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nb_wasi_path_open(state: *mut NativeState, bytes: *mut u8, len: usize, a0: u32, a1: u32, a2: u32, a3: u32, a4: u32, a5: u64, a6: u64, a7: u32, a8: u32) -> u32 {
  let state = unsafe { &mut *state };
  if state.check() { return u32::MAX; }
  let mut memory = wiggle::GuestMemory::Unshared(unsafe { std::slice::from_raw_parts_mut(bytes, len) });
  let future = wasi::path_open(&mut state.wasi, &mut memory, a0 as i32, a1 as i32, a2 as i32, a3 as i32, a4 as i32, a5 as i64, a6 as i64, a7 as i32, a8 as i32);
  match pin!(future).poll(&mut Context::from_waker(Waker::noop())) {
    Poll::Ready(Ok(result)) => result as u32,
    Poll::Ready(Err(error)) => { state.failure = Some(error.to_string()); u32::MAX },
    Poll::Pending => { state.failure = Some("Blocking WASI operation denied".into()); u32::MAX },
  }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nb_wasi_path_remove_directory(state: *mut NativeState, bytes: *mut u8, len: usize, a0: u32, a1: u32, a2: u32) -> u32 {
  let state = unsafe { &mut *state };
  if state.check() { return u32::MAX; }
  let mut memory = wiggle::GuestMemory::Unshared(unsafe { std::slice::from_raw_parts_mut(bytes, len) });
  let future = wasi::path_remove_directory(&mut state.wasi, &mut memory, a0 as i32, a1 as i32, a2 as i32);
  match pin!(future).poll(&mut Context::from_waker(Waker::noop())) {
    Poll::Ready(Ok(result)) => result as u32,
    Poll::Ready(Err(error)) => { state.failure = Some(error.to_string()); u32::MAX },
    Poll::Pending => { state.failure = Some("Blocking WASI operation denied".into()); u32::MAX },
  }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nb_wasi_path_unlink_file(state: *mut NativeState, bytes: *mut u8, len: usize, a0: u32, a1: u32, a2: u32) -> u32 {
  let state = unsafe { &mut *state };
  if state.check() { return u32::MAX; }
  let mut memory = wiggle::GuestMemory::Unshared(unsafe { std::slice::from_raw_parts_mut(bytes, len) });
  let future = wasi::path_unlink_file(&mut state.wasi, &mut memory, a0 as i32, a1 as i32, a2 as i32);
  match pin!(future).poll(&mut Context::from_waker(Waker::noop())) {
    Poll::Ready(Ok(result)) => result as u32,
    Poll::Ready(Err(error)) => { state.failure = Some(error.to_string()); u32::MAX },
    Poll::Pending => { state.failure = Some("Blocking WASI operation denied".into()); u32::MAX },
  }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nb_wasi_random_get(state: *mut NativeState, bytes: *mut u8, len: usize, a0: u32, a1: u32) -> u32 {
  let state = unsafe { &mut *state };
  if state.check() { return u32::MAX; }
  let mut memory = wiggle::GuestMemory::Unshared(unsafe { std::slice::from_raw_parts_mut(bytes, len) });
  let future = wasi::random_get(&mut state.wasi, &mut memory, a0 as i32, a1 as i32);
  match pin!(future).poll(&mut Context::from_waker(Waker::noop())) {
    Poll::Ready(Ok(result)) => result as u32,
    Poll::Ready(Err(error)) => { state.failure = Some(error.to_string()); u32::MAX },
    Poll::Pending => { state.failure = Some("Blocking WASI operation denied".into()); u32::MAX },
  }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nb_wasi_proc_exit(state: *mut NativeState, bytes: *mut u8, len: usize, a0: u32) -> u32 {
  let state = unsafe { &mut *state };
  if state.check() { return u32::MAX; }
  let mut memory = wiggle::GuestMemory::Unshared(unsafe { std::slice::from_raw_parts_mut(bytes, len) });
  let future = wasi::proc_exit(&mut state.wasi, &mut memory, a0 as i32);
  match pin!(future).poll(&mut Context::from_waker(Waker::noop())) {
    Poll::Ready(Ok(result)) => { let _ = result; 0 },
    Poll::Ready(Err(error)) => { state.failure = Some(error.to_string()); u32::MAX },
    Poll::Pending => { state.failure = Some("Blocking WASI operation denied".into()); u32::MAX },
  }
}
