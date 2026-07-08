use lazy_static::lazy_static;
use prometheus::{IntCounter, IntCounterVec, IntGauge};
use prometheus::{opts, register_int_counter_vec, register_int_gauge};

lazy_static! {
    pub static ref MESSAGES_TOTAL: IntCounterVec = register_int_counter_vec!(
        opts!("zumble_messages_total", "number of messages"),
        &["protocol", "direction", "kind"]
    )
    .expect("can't create a metric");
    pub static ref MESSAGES_BYTES: IntCounterVec =
        register_int_counter_vec!(opts!("zumble_messages_bytes", "message bytes"), &["protocol", "direction", "kind"])
            .expect("can't create a metric");
    pub static ref CLIENTS_TOTAL: IntGauge =
        register_int_gauge!(opts!("zumble_clients_total", "Total number of clients")).expect("can't create a metric");
    pub static ref UNKNOWN_MESSAGES_TOTAL: IntCounterVec = register_int_counter_vec!(
        opts!(
            "zumble_unknown_messages_total",
            "number of unknown messages (sent from clients not initialized)"
        ),
        &["protocol", "direction", "kind"]
    )
    .expect("can't create a metric");
    pub static ref UNKNOWN_MESSAGES_BYTES: IntCounterVec = register_int_counter_vec!(
        opts!(
            "zumble_unknown_messages_bytes",
            "unknown message bytes (sent from clients not initialized)"
        ),
        &["protocol", "direction", "kind"]
    )
    .expect("can't create a metric");
    pub static ref CRYPT_RESETS: IntGauge = register_int_gauge!(opts!(
        "zumble_crypt_resets",
        "the amount of clients that got a crypt reset (not unique)"
    ))
    .expect("can't create metric");
    pub static ref DISCONNECT: IntCounterVec = register_int_counter_vec!(
        opts!("zumble_disconnect", "unknown message bytes (sent from clients not initialized)"),
        &["disconnect_reason"]
    )
    .expect("can't create a metric");

    // Cached label-bound counters for the hottest UDP voice paths (audio + ping traffic), which
    // get recorded on every single UDP packet handled by the server. `with_label_values` hashes
    // the label set and takes a read lock on the vec's internal map on every call; since these
    // specific label combinations are fixed and known ahead of time, we resolve them once here
    // and reuse the handle instead of paying that cost per packet.
    pub static ref VOICE_PACKET_UDP_INPUT_TOTAL: IntCounter = MESSAGES_TOTAL.with_label_values(&["udp", "input", "VoicePacket"]);
    pub static ref VOICE_PACKET_UDP_INPUT_BYTES: IntCounter = MESSAGES_BYTES.with_label_values(&["udp", "input", "VoicePacket"]);
    pub static ref VOICE_PACKET_UDP_OUTPUT_TOTAL: IntCounter = MESSAGES_TOTAL.with_label_values(&["udp", "output", "VoicePacket"]);
    pub static ref VOICE_PACKET_UDP_OUTPUT_BYTES: IntCounter = MESSAGES_BYTES.with_label_values(&["udp", "output", "VoicePacket"]);
    pub static ref VOICE_PING_UDP_INPUT_TOTAL: IntCounter = MESSAGES_TOTAL.with_label_values(&["udp", "input", "VoicePing"]);
    pub static ref VOICE_PING_UDP_INPUT_BYTES: IntCounter = MESSAGES_BYTES.with_label_values(&["udp", "input", "VoicePing"]);
    pub static ref VOICE_PING_UDP_OUTPUT_TOTAL: IntCounter = MESSAGES_TOTAL.with_label_values(&["udp", "output", "VoicePing"]);
    pub static ref VOICE_PING_UDP_OUTPUT_BYTES: IntCounter = MESSAGES_BYTES.with_label_values(&["udp", "output", "VoicePing"]);
    pub static ref PING_ANONYMOUS_INPUT_TOTAL: IntCounter = MESSAGES_TOTAL.with_label_values(&["udp", "input", "PingAnonymous"]);
    pub static ref PING_ANONYMOUS_INPUT_BYTES: IntCounter = MESSAGES_BYTES.with_label_values(&["udp", "input", "PingAnonymous"]);
}
