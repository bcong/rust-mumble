use crate::client::{ClientArc, WeakClient};
use crate::error::DisconnectReason;
use crate::message::ClientMessage;
use crate::state::ServerStateRef;
use crate::voice::{ClientBound, VoicePacket};
use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::Ordering;

use super::{Handler, MumbleResult};

// shield your eyes
impl Handler for VoicePacket<ClientBound> {
    async fn handle(&self, state: &ServerStateRef, client: &ClientArc) -> MumbleResult {
        let mute = client.is_muted();

        if mute {
            return Ok(());
        }

        if let VoicePacket::<ClientBound>::Audio { target, session_id, .. } = self {
            // This is a per-packet, single-task local collection used only to dedupe and gather
            // recipients for this one packet - it never escapes this function call, so a plain
            // HashMap is used instead of the concurrent map to avoid locking/EBR guard overhead
            // on this hot path (this runs for every voice packet received).
            let mut listening_clients: HashMap<u32, WeakClient> = HashMap::new();

            match *target {
                // Channel
                0 => {
                    let channel_id = client.channel_id.load(Ordering::Relaxed);

                    if let Some(c) = state.get_channel_by_channel_id(channel_id).await
                        && let Some(channel) = c.upgrade()
                    {
                        let mut iter = channel.clients.first_entry_async().await;
                        while let Some(entry) = iter {
                            let session_id = entry.key();
                            let client = entry.get();
                            listening_clients.insert(*session_id, Arc::downgrade(client));
                            iter = entry.next_async().await;
                        }

                        // Also relay to clients "listening" to this channel from elsewhere
                        // (added via `UserState::listening_channel_add`, Mumble's "Channel
                        // Listening" feature), not just literal members. This must cover
                        // ordinary talk (this target=0 branch), not only explicit whisper/
                        // voice-target audio (the 1..=30 branch below already includes
                        // listeners) - otherwise radio/dispatch scripts that monitor a channel
                        // without switching into it would silently miss all normal chatter.
                        let mut listener_iter = channel.listeners.first_entry_async().await;
                        while let Some(entry) = listener_iter {
                            let session_id = entry.key();
                            let client = entry.get();
                            listening_clients.insert(*session_id, Arc::downgrade(client));
                            listener_iter = entry.next_async().await;
                        }
                    }
                }
                // Voice target (whisper)
                1..=30 => {
                    let target = client.get_target(*target);

                    if let Some(target) = target {
                        {
                            let mut iter = target.sessions.first_entry_async().await;
                            while let Some(entry) = iter {
                                let session = entry.key();
                                if let Some(client) = state.clients.get_async(session).await {
                                    listening_clients.insert(*session, Arc::downgrade(client.get()));
                                }
                                iter = entry.next_async().await;
                            }
                        }

                        {
                            let mut iter = target.channels.first_entry_async().await;
                            while let Some(entry) = iter {
                                let channel_id = entry.key();
                                if let Some(target_channel) = state.channels.get_async(channel_id).await {
                                    {
                                        let mut listener_iter = target_channel.get().listeners.first_entry_async().await;
                                        while let Some(listener_entry) = listener_iter {
                                            let session_id = listener_entry.key();
                                            let client = listener_entry.get();
                                            listening_clients.insert(*session_id, Arc::downgrade(client));
                                            listener_iter = listener_entry.next_async().await;
                                        }
                                    }

                                    {
                                        let mut client_iter = target_channel.get().clients.first_entry_async().await;
                                        while let Some(client_entry) = client_iter {
                                            let session_id = client_entry.key();
                                            let client = client_entry.get();
                                            listening_clients.insert(*session_id, Arc::downgrade(client));
                                            client_iter = client_entry.next_async().await;
                                        }
                                    }
                                }
                                iter = entry.next_async().await;
                            }
                        }
                    }
                }
                // Loopback
                31 => {
                    client.send_voice_packet(self.clone()).await?;

                    return Ok(());
                }
                _ => {
                    tracing::error!("invalid voice target: {}", *target);
                }
            }

            // remove the calling client from the session list so we don't have to branch here.
            listening_clients.remove(session_id);

            for cl in listening_clients.values() {
                if let Some(cl) = cl.upgrade() {
                    if !cl.is_deaf() {
                        let _ = cl.publisher.try_send(ClientMessage::SendVoicePacket(self.clone())).map_err(|_e| {
                            state.add_client_to_disconnect_queue(cl.session_id, DisconnectReason::ClientMSPCFull);
                        });
                    }
                }
            }
        }

        Ok(())
    }
}
