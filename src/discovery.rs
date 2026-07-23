use std::{
    collections::HashMap,
    net::{IpAddr, Ipv4Addr, SocketAddr, SocketAddrV4},
    time::Duration,
};

use mdns_sd::{DaemonEvent, ResolvedService, ServiceDaemon, ServiceEvent, ServiceInfo};
use tokio::{
    task::JoinHandle,
    time::{timeout, Instant},
};
use tracing::warn;

use crate::protocol::VERSION;

pub(crate) const SERVICE_TYPE: &str = "_gitler._udp.local.";

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Peer {
    pub(crate) id: String,
    pub(crate) name: String,
    pub(crate) address: SocketAddr,
    pub(crate) fingerprint: [u8; 32],
}

#[derive(Debug, thiserror::Error)]
pub(crate) enum DiscoveryError {
    #[error("mDNS operation failed: {0}")]
    Mdns(String),
}

pub(crate) struct Advertisement {
    daemon: Option<ServiceDaemon>,
    monitor_task: JoinHandle<()>,
}

impl Advertisement {
    pub(crate) fn publish(
        name: &str,
        port: u16,
        fingerprint: [u8; 32],
        bind: Ipv4Addr,
    ) -> Result<Self, DiscoveryError> {
        let daemon = ServiceDaemon::new().map_err(mdns_error)?;
        let fingerprint_hex = hex::encode(fingerprint);
        let id = fingerprint_hex[..12].to_owned();
        let properties = HashMap::from([
            ("version".to_owned(), VERSION.to_string()),
            ("id".to_owned(), id.clone()),
            ("name".to_owned(), name.to_owned()),
            ("fingerprint".to_owned(), fingerprint_hex),
        ]);
        let host_name = format!("gitler-{id}.local.");
        let instance_name = instance_name(name, &id);
        let service = if bind.is_unspecified() {
            ServiceInfo::new(
                SERVICE_TYPE,
                &instance_name,
                &host_name,
                (),
                port,
                properties,
            )
            .map_err(mdns_error)?
            .enable_addr_auto()
        } else {
            ServiceInfo::new(
                SERVICE_TYPE,
                &instance_name,
                &host_name,
                IpAddr::V4(bind),
                port,
                properties,
            )
            .map_err(mdns_error)?
        };

        let monitor = daemon.monitor().map_err(mdns_error)?;
        let monitor_task = tokio::spawn(async move {
            while let Ok(event) = monitor.recv_async().await {
                if let DaemonEvent::Error(error) = event {
                    warn!(%error, "mDNS advertisement error");
                }
            }
        });
        if let Err(error) = daemon.register(service) {
            monitor_task.abort();
            let _ = daemon.shutdown();
            return Err(mdns_error(error));
        }

        Ok(Self {
            daemon: Some(daemon),
            monitor_task,
        })
    }

    pub(crate) fn shutdown(&mut self) {
        self.monitor_task.abort();
        shutdown_daemon(&mut self.daemon);
    }
}

impl Drop for Advertisement {
    fn drop(&mut self) {
        self.monitor_task.abort();
        shutdown_daemon(&mut self.daemon);
    }
}

pub(crate) async fn discover_peers(duration: Duration) -> Result<Vec<Peer>, DiscoveryError> {
    let daemon = ServiceDaemon::new().map_err(mdns_error)?;
    let guard = DaemonGuard(daemon);
    let events = guard.daemon().browse(SERVICE_TYPE).map_err(mdns_error)?;
    let monitor = guard.daemon().monitor().map_err(mdns_error)?;
    let deadline = Instant::now() + duration;
    let mut peers = HashMap::<String, Peer>::new();

    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            break;
        }

        let next = timeout(remaining, async {
            tokio::select! {
                event = events.recv_async() => match event {
                    Ok(ServiceEvent::ServiceResolved(service)) => Ok(parse_peer(&service)),
                    Ok(_) => Ok(None),
                    Err(error) => Err(DiscoveryError::Mdns(error.to_string())),
                },
                event = monitor.recv_async() => match event {
                    Ok(DaemonEvent::Error(error)) => Err(mdns_error(error)),
                    Ok(_) => Ok(None),
                    Err(error) => Err(DiscoveryError::Mdns(error.to_string())),
                },
            }
        })
        .await;

        match next {
            Ok(Ok(Some(peer))) => {
                peers.insert(peer.id.clone(), peer);
            }
            Ok(Ok(None)) => {}
            Ok(Err(error)) => return Err(error),
            Err(_) => break,
        }
    }

    let _ = guard.daemon().stop_browse(SERVICE_TYPE);

    let mut peers: Vec<_> = peers.into_values().collect();
    peers.sort_by_cached_key(|peer| peer.name.to_lowercase());
    Ok(peers)
}

pub(crate) fn local_device_name() -> String {
    hostname::get()
        .ok()
        .and_then(|name| name.into_string().ok())
        .filter(|name| !name.trim().is_empty())
        .unwrap_or_else(|| "gitler-device".to_owned())
}

fn parse_peer(service: &ResolvedService) -> Option<Peer> {
    if service
        .get_property_val_str("version")?
        .parse::<u16>()
        .ok()?
        != VERSION
    {
        return None;
    }

    let advertised_id = service.get_property_val_str("id")?.trim();
    let fingerprint_hex = service.get_property_val_str("fingerprint")?;
    let mut fingerprint = [0_u8; 32];
    hex::decode_to_slice(fingerprint_hex, &mut fingerprint).ok()?;
    let id = hex::encode(&fingerprint[..6]);
    if !advertised_id.eq_ignore_ascii_case(&id) {
        return None;
    }

    let name = service
        .get_property_val_str("name")
        .map(str::trim)
        .filter(|name| !name.is_empty())
        .unwrap_or(&id)
        .to_owned();

    let mut addresses: Vec<Ipv4Addr> = service
        .get_addresses_v4()
        .into_iter()
        .filter(|address| !address.is_unspecified() && !address.is_multicast())
        .collect();
    addresses.sort_by_key(|address| (address.is_loopback(), *address));
    let address = SocketAddr::V4(SocketAddrV4::new(*addresses.first()?, service.get_port()));

    Some(Peer {
        id,
        name,
        address,
        fingerprint,
    })
}

fn instance_name(name: &str, id: &str) -> String {
    let sanitized: String = name
        .chars()
        .filter(|character| character.is_ascii_alphanumeric() || matches!(character, '-' | '_'))
        .take(40)
        .collect();
    let prefix = if sanitized.is_empty() {
        "gitler"
    } else {
        &sanitized
    };
    format!("{prefix}-{id}")
}

fn mdns_error(error: mdns_sd::Error) -> DiscoveryError {
    DiscoveryError::Mdns(error.to_string())
}

fn shutdown_daemon(daemon: &mut Option<ServiceDaemon>) {
    let Some(daemon) = daemon.take() else {
        return;
    };
    if let Ok(status) = daemon.shutdown() {
        let _ = status.recv_timeout(Duration::from_secs(1));
    }
}

struct DaemonGuard(ServiceDaemon);

impl DaemonGuard {
    fn daemon(&self) -> &ServiceDaemon {
        &self.0
    }
}

impl Drop for DaemonGuard {
    fn drop(&mut self) {
        if let Ok(status) = self.0.shutdown() {
            let _ = status.recv_timeout(Duration::from_secs(1));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::instance_name;

    #[test]
    fn instance_name_should_remove_dns_hostile_characters() {
        assert_eq!(instance_name("My laptop!", "abc123"), "Mylaptop-abc123");
    }

    #[test]
    fn instance_name_should_use_fallback_when_name_is_empty() {
        assert_eq!(instance_name("!!!", "abc123"), "gitler-abc123");
    }
}
