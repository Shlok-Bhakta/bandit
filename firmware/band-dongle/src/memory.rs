//! Where the heap goes, for the log: free and largest block, NimBLE's buffer pools and every
//! task's unused stack. The pools and stacks are what the sizes in sdkconfig.defaults and the
//! threads' `stack_size`s were cut to, so their slack is logged now and then.

use esp_idf_svc::sys;

/// `memory: largest free block …, lowest free since boot …, free now …`.
pub fn summary() -> String {
    let (largest, lowest, free) = unsafe {
        (sys::heap_caps_get_largest_free_block(sys::MALLOC_CAP_8BIT),
         sys::heap_caps_get_minimum_free_size(sys::MALLOC_CAP_8BIT),
         sys::heap_caps_get_free_size(sys::MALLOC_CAP_8BIT))
    };
    format!("largest free block {largest} B, lowest free since boot {lowest} B, free now {free} B")
}

/// Free heap now, for marking what each step of starting up took.
pub fn free() -> usize { unsafe { sys::heap_caps_get_free_size(sys::MALLOC_CAP_8BIT) } }

/// Each mempool (NimBLE's and the L2CAP channel's): `name blocks×size min free`.
pub fn pools() -> String {
    let mut parts = Vec::new();
    let mut pool: *mut sys::os_mempool = std::ptr::null_mut();
    loop {
        let mut info: sys::os_mempool_info = Default::default();
        pool = unsafe { sys::os_mempool_info_get_next(pool, &mut info) };
        if pool.is_null() { break; }
        let name = unsafe { std::ffi::CStr::from_ptr(info.omi_name.as_ptr()) }.to_string_lossy().into_owned();
        parts.push(format!("{name} {}x{} min free {}", info.omi_num_blocks, info.omi_block_size, info.omi_min_free));
    }
    parts.join(", ")
}

/// Every task's stack never used so far, in bytes: `name hwm`.
pub fn stacks() -> String {
    let count = unsafe { sys::uxTaskGetNumberOfTasks() } as usize;
    let mut tasks: Vec<sys::TaskStatus_t> = Vec::with_capacity(count + 2);
    let filled = unsafe { sys::uxTaskGetSystemState(tasks.as_mut_ptr(), tasks.capacity() as _, std::ptr::null_mut()) } as usize;
    unsafe { tasks.set_len(filled) };
    tasks.sort_by_key(|task| task.xTaskNumber);
    tasks.iter().map(|task| {
        let name = unsafe { std::ffi::CStr::from_ptr(task.pcTaskName) }.to_string_lossy();
        format!("{name}#{} {}", task.xTaskNumber, task.usStackHighWaterMark)
    }).collect::<Vec<_>>().join(", ")
}

/// This task's stack never used so far, in bytes.
pub fn own_stack_unused() -> u32 { unsafe { sys::uxTaskGetStackHighWaterMark2(std::ptr::null_mut()) } }

/// A thread whose task is called `name` (they're all "pthread" otherwise, so `stacks` couldn't
/// tell them apart), with `stack` bytes of stack.
pub fn spawn<F: FnOnce() + Send + 'static>(name: &'static std::ffi::CStr, stack: usize, f: F)
                                          -> std::io::Result<std::thread::JoinHandle<()>> {
    spawn_with(name, stack, None, f)
}

/// `spawn` at `priority` (1-24), not the default.
pub fn spawn_with<F: FnOnce() + Send + 'static>(name: &'static std::ffi::CStr, stack: usize, priority: Option<u8>, f: F)
                                               -> std::io::Result<std::thread::JoinHandle<()>> {
    use esp_idf_svc::hal::task::thread::ThreadSpawnConfiguration;
    let default = ThreadSpawnConfiguration::default();
    let priority = priority.unwrap_or(default.priority);
    let _ = ThreadSpawnConfiguration { name: Some(name), stack_size: stack, priority, ..default }.set();
    let spawned = std::thread::Builder::new().stack_size(stack).spawn(f);
    let _ = ThreadSpawnConfiguration::default().set();
    spawned
}
