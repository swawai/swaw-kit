use std::{
    io,
    net::{Ipv4Addr, SocketAddr},
};

use tokio::net::TcpListener;

const MAX_BIND_ATTEMPTS: usize = 32;

// WHATWG Fetch Standard, section 2.9, "Port blocking".
// Keep this exact and sorted so every browser-facing Host URL is fetchable.
const BAD_PORTS: &[u16] = &[
    0, 1, 7, 9, 11, 13, 15, 17, 19, 20, 21, 22, 23, 25, 37, 42, 43, 53, 69, 77, 79, 87, 95, 101,
    102, 103, 104, 109, 110, 111, 113, 115, 117, 119, 123, 135, 137, 139, 143, 161, 179, 389, 427,
    465, 512, 513, 514, 515, 526, 530, 531, 532, 540, 548, 554, 556, 563, 587, 601, 636, 989, 990,
    993, 995, 1719, 1720, 1723, 2049, 3659, 4045, 4190, 5060, 5061, 6000, 6566, 6665, 6666, 6667,
    6668, 6669, 6679, 6697, 10080,
];

pub(super) async fn bind_browser_safe() -> io::Result<TcpListener> {
    for _ in 0..MAX_BIND_ATTEMPTS {
        let listener = TcpListener::bind(SocketAddr::from((Ipv4Addr::LOCALHOST, 0))).await?;
        let port = listener.local_addr()?.port();
        if is_browser_safe(port) {
            return Ok(listener);
        }
    }

    Err(io::Error::new(
        io::ErrorKind::AddrNotAvailable,
        "Windows did not allocate a browser-safe loopback port",
    ))
}

fn is_browser_safe(port: u16) -> bool {
    BAD_PORTS.binary_search(&port).is_err()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_the_fetch_standard_bad_ports() {
        assert!(BAD_PORTS.windows(2).all(|ports| ports[0] < ports[1]));
        assert!(BAD_PORTS.iter().all(|port| !is_browser_safe(*port)));
        assert!(!is_browser_safe(6665));
        assert!(is_browser_safe(6664));
        assert!(is_browser_safe(6670));
    }

    #[tokio::test]
    async fn binds_a_browser_safe_loopback_port() {
        let listener = bind_browser_safe().await.unwrap();
        let address = listener.local_addr().unwrap();

        assert_eq!(address.ip(), Ipv4Addr::LOCALHOST);
        assert!(is_browser_safe(address.port()));
    }
}
