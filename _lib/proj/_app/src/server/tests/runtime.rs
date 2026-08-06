use std::{
    io::{Read, Write},
    net::TcpStream,
    sync::mpsc,
    time::Duration,
};

use super::*;

#[tokio::test]
async fn binds_independent_random_ports_on_ipv4_loopback() {
    let first = bind_loopback().await.expect("first listener");
    let second = bind_loopback().await.expect("second listener");
    let first_address = first.local_addr().expect("first address");
    let second_address = second.local_addr().expect("second address");

    assert_eq!(first_address.ip(), Ipv4Addr::LOCALHOST);
    assert_eq!(second_address.ip(), Ipv4Addr::LOCALHOST);
    assert_ne!(first_address.port(), 0);
    assert_ne!(second_address.port(), 0);
    assert_ne!(first_address.port(), second_address.port());
}

#[test]
fn shutdown_signal_stops_the_live_http_server() {
    let fixture = Fixture::new();
    fixture.directory("home/_lib/proj");
    let (events, received_events) = mpsc::channel();
    let (shutdown, shutdown_receiver) = oneshot::channel();
    let server_thread = spawn(
        fixture.context(),
        fixture.data_root_session(),
        move |event| events.send(event).map_err(|error| error.to_string()),
        shutdown_receiver,
    )
    .expect("server thread");

    let ready = received_events
        .recv_timeout(Duration::from_secs(5))
        .expect("ready event");
    let ServerEvent::Ready(url) = ready else {
        panic!("expected ready event");
    };
    let authority = url
        .strip_prefix("http://")
        .and_then(|value| value.strip_suffix('/'))
        .expect("loopback URL");

    let mut stream = TcpStream::connect(authority).expect("HTTP connection");
    write!(
        stream,
        "GET /healthz HTTP/1.1\r\nHost: {authority}\r\nConnection: close\r\n\r\n"
    )
    .expect("HTTP request");
    let mut response = String::new();
    stream.read_to_string(&mut response).expect("HTTP response");
    assert!(response.starts_with("HTTP/1.1 200 OK\r\n"));
    assert!(response.ends_with("\r\nok\n"));

    shutdown.send(()).expect("shutdown signal");
    let stopped = received_events
        .recv_timeout(Duration::from_secs(5))
        .expect("stopped event");
    assert!(matches!(stopped, ServerEvent::Stopped(Ok(()))));
    server_thread.join().expect("clean server thread");
}
