//! Router integrations (REQ: API-010 naming sources, M8 "router integrations"; T8.2): device
//! names and addresses read from the router's DHCP, so devices show up by name without
//! TelltaleDNS running DHCP itself.
//! - **UniFi** (UniFi OS consoles: UDM, UCG, Cloud Key Gen2+; and the classic Network
//!   application): the active clients (`stat/sta`), named by their UniFi alias, else their
//!   host name. An API key (`X-API-KEY`), or a local username and password.
//! - **OPNsense**: the DHCP leases (Dnsmasq, Kea, or ISC, whichever the box runs), with an
//!   API key and secret.
//!
//! Polled every `interval_secs`; the result replaces that router's part of the lease view
//! the naming falls back to (after configured device names and TelltaleDNS's own DHCP).
//! Never on the DNS path; a router that's down keeps its last answer and is logged.

use std::collections::HashMap;
use std::net::{IpAddr, Ipv4Addr};
use std::sync::Arc;
use std::time::Duration;

use arc_swap::ArcSwap;
use serde_json::Value;
use telltale_config::{RouterConfig, RouterKind};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixStream;
use tracing::{info, warn};

use crate::devices::{Lease, Leases};

/// Most bytes one answer may have.
const MAX_ANSWER: u64 = 16 << 20;

/// What a router reported: (MAC, IPv4 address, name).
pub(crate) type Seen = Vec<(String, Ipv4Addr, Option<String>)>;

fn secret(path: Option<&telltale_config::SafeString>) -> Result<Option<String>, String> {
    path.map(|p| {
        std::fs::read_to_string(p.as_str())
            .map(|s| s.trim().to_owned())
            .map_err(|e| format!("{}: {e}", p.as_str()))
    })
    .transpose()
}

fn base64(input: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    for chunk in input.chunks(3) {
        let b = [
            chunk[0],
            *chunk.get(1).unwrap_or(&0),
            *chunk.get(2).unwrap_or(&0),
        ];
        let n = (u32::from(b[0]) << 16) | (u32::from(b[1]) << 8) | u32::from(b[2]);
        for i in 0..4 {
            if i <= chunk.len() {
                out.push(char::from(
                    T[usize::try_from((n >> (18 - 6 * i)) & 63).unwrap_or(0)],
                ));
            } else {
                out.push('=');
            }
        }
    }
    out
}

/// One HTTP exchange; the JSON body and the response headers.
async fn call(
    client: &telltale_filter::fetch::Client,
    req: http::Request<Vec<u8>>,
) -> Result<(http::StatusCode, http::HeaderMap, Value), String> {
    let url = req.uri().to_string();
    let resp = tokio::time::timeout(Duration::from_secs(15), client.request(req, MAX_ANSWER))
        .await
        .map_err(|_| format!("{url}: timed out"))?
        .map_err(|e| format!("{url}: {}", e.message))?;
    let status = resp.status();
    let headers = resp.headers().clone();
    let body = resp.into_body();
    let v = serde_json::from_slice(&body).unwrap_or(Value::Null);
    Ok((status, headers, v))
}

/// The `name=value` pairs of every `Set-Cookie`.
fn cookies(h: &http::HeaderMap) -> String {
    h.get_all(http::header::SET_COOKIE)
        .iter()
        .filter_map(|v| v.to_str().ok())
        .filter_map(|c| c.split(';').next())
        .collect::<Vec<_>>()
        .join("; ")
}

/// UniFi clients in a `stat/sta` (or `rest/user`) answer.
pub(crate) fn unifi_clients(v: &Value) -> Seen {
    let Some(data) = v.get("data").and_then(Value::as_array) else {
        return Vec::new();
    };
    data.iter()
        .filter_map(|c| {
            let mac = c.get("mac")?.as_str()?.to_ascii_lowercase();
            let ip: Ipv4Addr = c
                .get("ip")
                .or_else(|| c.get("last_ip"))
                .or_else(|| c.get("fixed_ip"))?
                .as_str()?
                .parse()
                .ok()?;
            let name = ["name", "hostname"]
                .iter()
                .filter_map(|k| c.get(*k).and_then(Value::as_str))
                .map(str::trim)
                .find(|s| !s.is_empty())
                .map(str::to_owned);
            Some((mac, ip, name))
        })
        .collect()
}

/// OPNsense leases in a search answer (Dnsmasq, Kea, or ISC field names).
pub(crate) fn opnsense_leases(v: &Value) -> Seen {
    let Some(rows) = v.get("rows").and_then(Value::as_array) else {
        return Vec::new();
    };
    rows.iter()
        .filter_map(|r| {
            let ip: Ipv4Addr = r.get("address")?.as_str()?.parse().ok()?;
            let mac = r
                .get("mac")
                .or_else(|| r.get("hwaddr"))?
                .as_str()?
                .to_ascii_lowercase();
            let name = ["hostname", "client_hostname", "descr"]
                .iter()
                .filter_map(|k| r.get(*k).and_then(Value::as_str))
                .map(str::trim)
                .find(|s| !s.is_empty() && *s != "*")
                .map(str::to_owned);
            Some((mac, ip, name))
        })
        .collect()
}

/// One poll of a UniFi console or Network application.
async fn poll_unifi(
    client: &telltale_filter::fetch::Client,
    c: &RouterConfig,
) -> Result<Seen, String> {
    let base = c.url.trim_end_matches('/');
    let site = c.site.as_deref().unwrap_or("default");
    if let Some(key) = secret(c.api_key_file.as_ref())? {
        let url = format!("{base}/proxy/network/api/s/{site}/stat/sta");
        let req = http::Request::get(url.as_str())
            .header("x-api-key", key)
            .header("accept", "application/json")
            .body(Vec::new())
            .map_err(|e| e.to_string())?;
        let (status, _, v) = call(client, req).await?;
        return if status.is_success() {
            Ok(unifi_clients(&v))
        } else {
            Err(format!("{url}: HTTP {status}"))
        };
    }
    let user = c
        .username
        .as_deref()
        .ok_or("set api_key_file, or username and password_file")?;
    let pass = secret(c.password_file.as_ref())?.ok_or("set password_file")?;
    let body =
        serde_json::json!({"username": user, "password": pass, "remember": false}).to_string();
    // UniFi OS consoles first, then the classic Network application.
    for (login, prefix) in [("/api/auth/login", "/proxy/network"), ("/api/login", "")] {
        let req = http::Request::post(format!("{base}{login}"))
            .header("content-type", "application/json")
            .header("accept", "application/json")
            .body(body.clone().into_bytes())
            .map_err(|e| e.to_string())?;
        let (status, headers, _) = call(client, req).await?;
        if status == http::StatusCode::NOT_FOUND {
            continue;
        }
        if !status.is_success() {
            return Err(format!(
                "{base}{login}: HTTP {status} (check the username and password)"
            ));
        }
        let cookie = cookies(&headers);
        let url = format!("{base}{prefix}/api/s/{site}/stat/sta");
        let req = http::Request::get(url.as_str())
            .header("cookie", cookie)
            .header("accept", "application/json")
            .body(Vec::new())
            .map_err(|e| e.to_string())?;
        let (status, _, v) = call(client, req).await?;
        return if status.is_success() {
            Ok(unifi_clients(&v))
        } else {
            Err(format!("{url}: HTTP {status}"))
        };
    }
    Err(format!(
        "{base}: neither a UniFi OS console nor a Network application"
    ))
}

/// One poll of an OPNsense box.
async fn poll_opnsense(
    client: &telltale_filter::fetch::Client,
    c: &RouterConfig,
) -> Result<Seen, String> {
    let base = c.url.trim_end_matches('/');
    let key = secret(c.api_key_file.as_ref())?.ok_or("set api_key_file")?;
    let sec = secret(c.api_secret_file.as_ref())?.ok_or("set api_secret_file")?;
    let auth = format!("Basic {}", base64(format!("{key}:{sec}").as_bytes()));
    let mut last = String::new();
    for path in [
        "/api/dnsmasq/leases/search",
        "/api/kea/leases4/search",
        "/api/dhcpv4/leases/searchLease",
    ] {
        let req = http::Request::get(format!("{base}{path}"))
            .header("authorization", auth.as_str())
            .header("accept", "application/json")
            .body(Vec::new())
            .map_err(|e| e.to_string())?;
        let (status, _, v) = call(client, req).await?;
        if status.is_success() && v.get("rows").is_some() {
            return Ok(opnsense_leases(&v));
        }
        if status == http::StatusCode::UNAUTHORIZED || status == http::StatusCode::FORBIDDEN {
            return Err(format!(
                "{base}: HTTP {status} (check the API key and its privileges)"
            ));
        }
        last = format!("{base}{path}: HTTP {status}");
    }
    Err(format!("no DHCP lease API answered ({last})"))
}

/// Tailscale peers in a `/localapi/v0/status` answer.
pub(crate) fn tailscale_clients(v: &Value) -> Seen {
    let mut seen = Vec::new();
    collect_tailscale_node(v.get("Self"), &mut seen);
    if let Some(peers) = v.get("Peer").and_then(Value::as_object) {
        for peer in peers.values() {
            collect_tailscale_node(Some(peer), &mut seen);
        }
    }
    seen
}

fn collect_tailscale_node(node: Option<&Value>, seen: &mut Seen) {
    let Some(node) = node else {
        return;
    };
    let hostname = ["HostName", "DNSName"]
        .iter()
        .filter_map(|k| node.get(*k).and_then(Value::as_str))
        .map(str::trim)
        .find(|s| !s.is_empty())
        .map(str::to_owned);
    let Some(ips) = node.get("TailscaleIPs").and_then(Value::as_array) else {
        return;
    };
    for ip in ips.iter().filter_map(Value::as_str) {
        if let Ok(IpAddr::V4(v4)) = ip.parse() {
            seen.push((String::new(), v4, hostname.clone()));
        }
    }
}

/// Read a JSON response from tailscaled's local API over its Unix socket.
async fn localapi_get(socket_path: &str, path: &str) -> Result<Value, String> {
    let mut stream = UnixStream::connect(socket_path)
        .await
        .map_err(|e| format!("{socket_path}: {e}"))?;
    let request = format!(
        "GET {path} HTTP/1.1\r\nHost: local-tailscaled.sock\r\nConnection: close\r\n\r\n"
    );
    stream
        .write_all(request.as_bytes())
        .await
        .map_err(|e| format!("{socket_path}: write: {e}"))?;
    let mut buf = Vec::new();
    stream
        .read_to_end(&mut buf)
        .await
        .map_err(|e| format!("{socket_path}: read: {e}"))?;
    let header_end = buf
        .windows(4)
        .position(|w| w == b"\r\n\r\n")
        .ok_or_else(|| "{socket_path}: malformed HTTP response".to_string())?;
    let status_end = buf
        .iter()
        .position(|&b| b == b'\r')
        .unwrap_or(buf.len());
    let status_line = std::str::from_utf8(&buf[..status_end])
        .map_err(|_| "{socket_path}: invalid status line".to_string())?;
    let status = status_line.split_whitespace().nth(1).unwrap_or("");
    if status != "200" {
        return Err(format!("{socket_path}: HTTP {status}"));
    }
    serde_json::from_slice(&buf[header_end + 4..])
        .map_err(|e| format!("{socket_path}: json: {e}"))
}

/// One poll of the local tailscaled daemon.
async fn poll_tailscale(c: &RouterConfig) -> Result<Seen, String> {
    let v = localapi_get(c.socket_path.as_str(), "/localapi/v0/status").await?;
    Ok(tailscale_clients(&v))
}

/// The leases view from every router's last answer.
fn rebuild(parts: &HashMap<String, Seen>, view: &ArcSwap<Leases>) {
    let mut m = Leases::new();
    for (source, seen) in parts {
        for (mac, ip, name) in seen {
            m.insert(
                *ip,
                Lease {
                    mac: mac.clone(),
                    ip: *ip,
                    hostname: name.clone(),
                    expires: 0,
                    source: source.clone(),
                },
            );
        }
    }
    view.store(Arc::new(m));
}

/// Polls every `[[router]]` until `stop`. `resolver_pod`: a Helm resolver pod, which has the
/// routers' settings but not their key files (ADR-120), logs its failures as info; the
/// controller, which serves the names in the UI, warns.
pub(crate) async fn run(
    routers: Vec<RouterConfig>,
    view: Arc<ArcSwap<Leases>>,
    mut stop: tokio::sync::watch::Receiver<bool>,
    resolver_pod: bool,
) {
    if routers.is_empty() {
        return;
    }
    let resolver: Arc<dyn telltale_filter::fetch::Resolve> =
        Arc::new(telltale_filter::fetch::SystemResolver);
    let mut parts: HashMap<String, Seen> = HashMap::new();
    let mut failing: HashMap<String, bool> = HashMap::new();
    let interval = routers
        .iter()
        .map(|r| r.interval_secs.max(30))
        .min()
        .unwrap_or(300);
    loop {
        for r in &routers {
            let result = if r.kind == RouterKind::Tailscale {
                poll_tailscale(r).await
            } else {
                let client = if r.tls_insecure_skip_verify {
                    telltale_filter::fetch::Client::insecure(Arc::clone(&resolver))
                } else if let Some(p) = &r.tls_ca {
                    telltale_filter::fetch::Client::with_ca_file(Arc::clone(&resolver), p.as_str())
                } else {
                    telltale_filter::fetch::Client::new(Arc::clone(&resolver), &[])
                };
                // Like a failed poll, a TLS setting that can't load (a node without the CA file, ADR-120)
                // is logged once until it works.
                let client = match client {
                    Ok(c) => c,
                    Err(e) => {
                        if !failing.get(r.name.as_str()).copied().unwrap_or(false) {
                            if resolver_pod {
                                info!(router = %r.name, error = %e, "router integration: TLS settings (not on this resolver pod; the controller reads the router)");
                            } else {
                                warn!(router = %r.name, error = %e, "router integration: TLS settings");
                            }
                        }
                        failing.insert(r.name.to_string(), true);
                        continue;
                    }
                };
                // REQ: T8.2 — a console whose certificate names something other than `url`'s host.
                let client = client.with_server_name(
                    r.tls_server_name
                        .as_ref()
                        .map(telltale_config::SafeString::as_str),
                );
                match r.kind {
                    RouterKind::Unifi => poll_unifi(&client, r).await,
                    RouterKind::Opnsense => poll_opnsense(&client, r).await,
                    RouterKind::Tailscale => unreachable!(),
                }
            };
            let was_failing = failing.get(r.name.as_str()).copied().unwrap_or(false);
            match result {
                Ok(seen) => {
                    if was_failing || !parts.contains_key(r.name.as_str()) {
                        info!(router = %r.name, devices = seen.len(), "router integration: devices read");
                    }
                    parts.insert(r.name.to_string(), seen);
                    failing.insert(r.name.to_string(), false);
                }
                Err(e) => {
                    if !was_failing {
                        if resolver_pod {
                            info!(router = %r.name, error = %e, "router integration failed on this resolver pod (the controller reads the router)");
                        } else {
                            warn!(router = %r.name, error = %e, "router integration failed (keeping its last answer)");
                        }
                    }
                    failing.insert(r.name.to_string(), true);
                }
            }
        }
        rebuild(&parts, &view);
        // A router that failed (it may still be booting) is asked again soon.
        let wait = if failing.values().any(|f| *f) {
            interval.min(15)
        } else {
            interval
        };
        tokio::select! {
            _ = stop.changed() => return,
            () = tokio::time::sleep(Duration::from_secs(u64::from(wait))) => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// REQ: T8.2 — UniFi's client list: the alias wins over the host name; clients without
    /// an IPv4 address are skipped.
    #[test]
    fn unifi_clients_named() {
        let v = serde_json::json!({"meta": {"rc": "ok"}, "data": [
            {"mac": "AA:BB:CC:00:00:01", "ip": "192.168.1.20", "hostname": "android-123", "name": "Kitchen tablet"},
            {"mac": "aa:bb:cc:00:00:02", "ip": "192.168.1.21", "hostname": "roku"},
            {"mac": "aa:bb:cc:00:00:03", "hostname": "no-ip"},
            {"mac": "aa:bb:cc:00:00:04", "last_ip": "192.168.1.22", "name": ""}
        ]});
        assert_eq!(
            unifi_clients(&v),
            vec![
                (
                    "aa:bb:cc:00:00:01".into(),
                    Ipv4Addr::new(192, 168, 1, 20),
                    Some("Kitchen tablet".into())
                ),
                (
                    "aa:bb:cc:00:00:02".into(),
                    Ipv4Addr::new(192, 168, 1, 21),
                    Some("roku".into())
                ),
                (
                    "aa:bb:cc:00:00:04".into(),
                    Ipv4Addr::new(192, 168, 1, 22),
                    None
                ),
            ]
        );
    }

    /// REQ: T8.2 — OPNsense leases, whichever DHCP server answered.
    #[test]
    fn opnsense_leases_any_backend() {
        let isc = serde_json::json!({"rows": [{"address": "10.0.0.5", "mac": "00:11:22:33:44:55", "hostname": "nas"}]});
        let kea = serde_json::json!({"rows": [{"address": "10.0.0.6", "hwaddr": "00:11:22:33:44:66", "hostname": "*"}]});
        assert_eq!(
            opnsense_leases(&isc),
            vec![(
                "00:11:22:33:44:55".into(),
                Ipv4Addr::new(10, 0, 0, 5),
                Some("nas".into())
            )]
        );
        assert_eq!(
            opnsense_leases(&kea),
            vec![("00:11:22:33:44:66".into(), Ipv4Addr::new(10, 0, 0, 6), None)]
        );
        assert_eq!(base64(b"key:secret"), "a2V5OnNlY3JldA==");
    }

    /// REQ: T8.2 — Tailscale local API status: IPv4 Tailscale IPs are named by HostName, with
    /// DNSName as a fallback; IPv6 IPs are ignored until the device table supports them.
    #[test]
    fn tailscale_clients_named() {
        let v = serde_json::json!({
            "Self": {
                "HostName": "home-dns",
                "DNSName": "home-dns.tail1234.ts.net",
                "TailscaleIPs": ["100.64.0.1", "fd7a:115c:a1e0::1"]
            },
            "Peer": {
                "abc123": {
                    "HostName": "alice-phone",
                    "DNSName": "alice-phone.tail1234.ts.net",
                    "TailscaleIPs": ["100.64.0.2", "100.64.0.3"]
                },
                "def456": {
                    "DNSName": "printer.tail1234.ts.net",
                    "TailscaleIPs": ["100.64.0.4"]
                }
            }
        });
        assert_eq!(
            tailscale_clients(&v),
            vec![
                (
                    String::new(),
                    Ipv4Addr::new(100, 64, 0, 1),
                    Some("home-dns".into())
                ),
                (
                    String::new(),
                    Ipv4Addr::new(100, 64, 0, 2),
                    Some("alice-phone".into())
                ),
                (
                    String::new(),
                    Ipv4Addr::new(100, 64, 0, 3),
                    Some("alice-phone".into())
                ),
                (
                    String::new(),
                    Ipv4Addr::new(100, 64, 0, 4),
                    Some("printer.tail1234.ts.net".into())
                ),
            ]
        );
    }

    #[test]
    fn tailscale_clients_no_peers() {
        let v = serde_json::json!({"Self": {"TailscaleIPs": []}});
        assert!(tailscale_clients(&v).is_empty());
    }
}
