/// TODO: Add these to a server.toml file so its easier to configure
/// The amount of players the server can support
pub const MAX_CLIENTS: usize = 4096;

/// the bandwidth (in bits) that the client can use
/// This mimics FiveM's current maximum
pub const MAX_BANDWIDTH_IN_BITS: u32 = 144_000;

/// Size (in bytes) requested for the UDP socket's kernel receive/send buffers. Sized generously
/// so bursts of voice traffic from many concurrent clients (e.g. a spike of people talking around
/// the same tick) queue up in the kernel instead of being silently dropped before our receive
/// tasks can drain the socket. The OS may cap this to a lower system-wide maximum; we log (rather
/// than fail) if the request can't be satisfied in full.
pub const UDP_SOCKET_BUFFER_SIZE: usize = 8 * 1024 * 1024;

// pub const MAX_BANDWIDTH_IN_BYTES: usize = MAX_BANDWIDTH_IN_BITS as usize / 8;

// So we can easily swap out the hash map if/when the need arises
pub type ConcurrentHashMap<K, V> = scc::HashIndex<K, V>;
