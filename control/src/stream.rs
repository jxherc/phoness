// brings up a coredevice screen media stream over displayservice.
//
// this is the auth gate for synthetic input: dtuhidd drops every tap, button and
// keystroke unless a media stream is live (the device checks the hid events came
// from an authenticated screen-sharing session). we never read the video it sends,
// we just keep the session open while we drive the phone.
//
// lifted from idevice's tools/coredevice_stream.rs, trimmed. the offer blobs mirror
// a device hub session the phone accepts.

use idevice::{
    ReadWrite, RsdService,
    core_device::{
        CallInfoBlob, DisplayServiceClient, build_screen_audio_offer, build_screen_video_offer,
        build_start_audio_parameters, build_start_video_parameters,
    },
    rsd::RsdHandshake,
    tcp::handle::{AdapterHandle, UdpSocketHandle},
};

// what we (the controller) support, not the device's mask. device hub sends 140 for
// screen sharing; the device's larger mask makes the negotiator build an invalid config.
const CLIENT_SUPPORTED_FEATURES: u64 = 140;

pub struct ScreenMediaStream {
    // held so the displayservice connection, and thus the stream, stays alive
    #[allow(dead_code)]
    pub client: DisplayServiceClient<Box<dyn ReadWrite>>,
    // the rtp receiver sockets. unread, but they have to stay bound or the ports close.
    pub _audio_udp: UdpSocketHandle,
    pub _video_udp: UdpSocketHandle,
}

pub async fn start(
    adapter: &mut AdapterHandle,
    handshake: &mut RsdHandshake,
    display_id: i64,
) -> Result<ScreenMediaStream, String> {
    let mut client = DisplayServiceClient::connect_rsd(adapter, handshake)
        .await
        .map_err(|e| format!("no display service: {e:?}"))?;

    let audio_udp = adapter.bind_udp(0).await.map_err(|e| format!("bind_udp(audio): {e:?}"))?;
    let video_udp = adapter.bind_udp(0).await.map_err(|e| format!("bind_udp(video): {e:?}"))?;
    let receiver_ip = adapter.host_ip().to_string();
    let audio_port = audio_udp.local_port();
    let video_port = video_udp.local_port();
    let sender_ip = adapter.peer_ip().to_string();

    let call_info = CallInfoBlob {
        call_id: 0,
        client_version: 1,
        device_type: "Mac17,7".into(),
        framework_version: "2205.3.1".into(),
        os_version: "25F71".into(),
        device_name: None,
        audio_device_uid: None,
    };
    // audio and video share one session id
    let session_id = uuid::Uuid::new_v4();

    // audio first, it establishes the session
    let audio_call = uuid::Uuid::new_v4().to_string().to_uppercase();
    let audio_offer =
        build_screen_audio_offer(&audio_call, &call_info).map_err(|e| format!("audio offer: {e:?}"))?;
    let audio_params = build_start_audio_parameters(
        &receiver_ip, audio_port, &sender_ip, 50000, audio_offer, CLIENT_SUPPORTED_FEATURES, session_id,
    );
    client.start_media_stream(audio_params).await.map_err(|e| format!("audio stream: {e:?}"))?;

    // then video on the same session
    let video_call = uuid::Uuid::new_v4().to_string().to_uppercase();
    let our_ssrc = uuid::Uuid::new_v4().as_u128() as u32;
    let video_offer = build_screen_video_offer(&video_call, &call_info, our_ssrc)
        .map_err(|e| format!("video offer: {e:?}"))?;
    let video_params = build_start_video_parameters(
        &receiver_ip, video_port, &sender_ip, 50001, video_offer, CLIENT_SUPPORTED_FEATURES, display_id, session_id,
    );
    client.start_media_stream(video_params).await.map_err(|e| format!("video stream: {e:?}"))?;

    Ok(ScreenMediaStream { client, _audio_udp: audio_udp, _video_udp: video_udp })
}
