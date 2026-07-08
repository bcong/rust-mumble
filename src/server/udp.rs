use crate::error::DecryptError;
use crate::message::ClientMessage;
use crate::state::ServerStateRef;
use crate::voice::VoicePacket;

use anyhow::anyhow;

use byteorder::{ReadBytesExt, WriteBytesExt};
use bytes::BytesMut;
use std::io::{Cursor, Read, Write};
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Instant;
use tokio::net::UdpSocket;
use tokio_util::sync::CancellationToken;

use super::constants::{MAX_BANDWIDTH_IN_BITS, MAX_CLIENTS};

pub async fn create_udp_server(protocol_version: u32, socket: Arc<UdpSocket>, state: ServerStateRef, _cancel_token: CancellationToken) {
    loop {
        match udp_server_run(protocol_version, socket.clone(), state.clone()).await {
            Ok(_) => (),
            Err(e) => tracing::error!("udp server error: {:?}", e),
        }
    }
}

async fn udp_server_run(protocol_version: u32, socket: Arc<UdpSocket>, state: ServerStateRef) -> Result<(), anyhow::Error> {
    // `with_capacity` + `recv_buf_from` avoids zero-filling 1024 bytes on every single incoming
    // UDP datagram; `recv_from` requires the destination buffer to already be fully initialized,
    // while `recv_buf_from` writes directly into the buffer's spare capacity via `BufMut`.
    let mut buffer = BytesMut::with_capacity(1024);
    if let Ok((size, addr)) = socket.recv_buf_from(&mut buffer).await {
        tokio::spawn(async move {
            match handle_packet(buffer, size, addr, protocol_version, socket, state).await {
                Ok(_) => (),
                Err(e) => tracing::error!("udp server handle packet error: {:?}", e),
            }
        });
    }

    Ok(())
}

async fn handle_packet(
    mut buffer: BytesMut,
    size: usize,
    addr: SocketAddr,
    protocol_version: u32,
    socket: Arc<UdpSocket>,
    state: ServerStateRef,
) -> Result<(), anyhow::Error> {
    if size <= 1 {
        return Err(anyhow!("Invalid packet"));
    }
    let mut cursor = Cursor::new(&buffer[..size]);
    let kind = cursor.read_u8()?;

    let kind = (kind >> 5) & 0x7;

    // respond to the server list ping packet
    if kind == 0 && size == 12 {
        // Per the Mumble "Non-RPC" out-of-band ping protocol (see mumble-voip/mumble-scripts'
        // Non-RPC/mumble-ping.py, used by tools like mumble_exporter and the official client's
        // server browser), the packet is a 4-byte zero magic marker followed by an opaque
        // 8-byte value (bytes [4..12)) chosen by the caller, which must be echoed back
        // completely unchanged so the caller can compute round-trip latency itself. This is
        // NOT a Mumble varint (a *variable*-length encoding used elsewhere in this protocol):
        // parsing it as one both starts at the wrong offset (right after the single type byte
        // already consumed above, instead of after the full 4-byte marker) and can consume a
        // different number of bytes than 8, corrupting the value -- silently breaking latency
        // reporting for every ping-based monitoring tool without ever causing an observable error.
        cursor.set_position(4);
        let mut timestamp = [0u8; 8];
        cursor.read_exact(&mut timestamp)?;

        let mut send = Cursor::new(vec![0u8; 24]);
        // server version
        send.write_u32::<byteorder::BigEndian>(protocol_version)?;
        // timestamp, echoed back byte-for-byte unchanged (caller interprets its own encoding)
        send.write_all(&timestamp)?;
        // user count
        send.write_u32::<byteorder::BigEndian>(state.active_clients.load(std::sync::atomic::Ordering::Relaxed))?;
        // max user count
        send.write_u32::<byteorder::BigEndian>(MAX_CLIENTS as u32)?;
        // max bandwidth per user
        send.write_u32::<byteorder::BigEndian>(MAX_BANDWIDTH_IN_BITS)?;

        socket.send_to(send.get_ref().as_slice(), addr).await?;

        crate::metrics::PING_ANONYMOUS_INPUT_TOTAL.inc();
        crate::metrics::PING_ANONYMOUS_INPUT_BYTES.inc_by(size as u64);

        return Ok(());
    }

    // This breaks when people are using VPN's, should add an option to use it for servers getting
    // hit by DDoS's
    // if !state.clients_by_peer.contains(&addr.ip()) {
    //     tracing::warn!(
    //         "UPP: User tried to connect with addr: {} but they didn't connect via TCP before.",
    //         addr
    //     );
    //     return Err(anyhow!("Not a valid peer"));
    // }

    let client_opt = state.get_client_by_socket(&addr).await;

    let (client, packet) = match client_opt {
        Some(client) => {
            // Send decrypt packet

            let (decrypt_result, last_good) = {
                let mut crypt_state = client.crypt_state.lock();
                (crypt_state.decrypt(&mut buffer), crypt_state.last_good)
            };

            match decrypt_result {
                Ok(p) => (client, p),
                Err(err) => {
                    tracing::warn!("client {} decrypt error: {}", client, err);

                    crate::metrics::VOICE_PACKET_UDP_INPUT_TOTAL.inc();
                    crate::metrics::VOICE_PACKET_UDP_INPUT_BYTES.inc_by(size as u64);

                    let restart_crypt = match err {
                        DecryptError::Late => {
                            let late = { client.crypt_state.lock().late };

                            late > 100
                        }
                        DecryptError::Repeat => false,
                        _ => true,
                    };

                    // if we haven't gotten a good packet for 5 seconds then we should reset the clients crypt
                    let restart_crypt = restart_crypt || Instant::now().duration_since(last_good).as_secs() > 5;

                    if restart_crypt {
                        tracing::error!("client {} udp decrypt error: {}, reset crypt setup", client, err);

                        if let Err(e) = state.reset_client_crypt(&client).await {
                            tracing::error!("failed to send crypt setup: {:?}", e);
                        }
                    }

                    return Ok(());
                }
            }
        }
        None => {
            if let Some((client, packet)) = state.find_client_with_decrypt(&mut buffer, addr).await? {
                tracing::info!("UDP connected client {} on {}", client, addr);

                (client, packet)
            } else {
                // don't log if we've done it recently
                // if let Ok(Some((_, _))) = state.logs.put(addr, ()) {
                //     tracing::error!("unknown client from address {}", addr);
                // }

                crate::metrics::UNKNOWN_MESSAGES_TOTAL
                    .with_label_values(&["udp", "input", "UnknownPackets"])
                    .inc();

                crate::metrics::UNKNOWN_MESSAGES_BYTES
                    .with_label_values(&["udp", "input", "UnknownPacket"])
                    .inc_by(size as u64);

                return Ok(());
            }
        }
    };

    let session_id = client.session_id;
    let client_packet = packet.into_client_bound(session_id, state.remove_positional_data);

    match &client_packet {
        VoicePacket::Ping { .. } => {
            crate::metrics::VOICE_PING_UDP_INPUT_TOTAL.inc();
            crate::metrics::VOICE_PING_UDP_INPUT_BYTES.inc_by(size as u64);

            // typical voice ping/audio packets are well under this, sized generously enough to
            // avoid a reallocation while encoding+encrypting into `dest` below.
            let mut dest = BytesMut::with_capacity(128);

            {
                let mut crypt = client.crypt_state.lock();
                crypt.encrypt(&client_packet, &mut dest);
            }

            client.last_udp_ping.store(Instant::now());
            let buf = &dest.freeze()[..];

            match socket.send_to(buf, addr).await {
                Ok(_) => {
                    crate::metrics::VOICE_PING_UDP_OUTPUT_TOTAL.inc();
                    crate::metrics::VOICE_PING_UDP_OUTPUT_BYTES.inc_by(buf.len() as u64);
                }
                Err(err) => {
                    tracing::error!("cannot send ping udp packet: {}", err);
                }
            }
        }
        _ => {
            crate::metrics::VOICE_PACKET_UDP_INPUT_TOTAL.inc();
            crate::metrics::VOICE_PACKET_UDP_INPUT_BYTES.inc_by(size as u64);

            let send_client_packet = {
                // if we fail to send via the publisher we should drop the client
                client
                    .publisher
                    .try_send(ClientMessage::RouteVoicePacket(client_packet))
                    .map_err(|e| {
                        state.add_client_to_disconnect_queue(session_id, crate::error::DisconnectReason::ClientMSPCFull);
                        e
                    })
            };

            match send_client_packet {
                Ok(_) => (),
                Err(err) => {
                    tracing::error!("cannot send voice packet to client: {}", err);
                }
            }
        }
    }

    Ok(())
}
