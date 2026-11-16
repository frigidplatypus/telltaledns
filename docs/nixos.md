# NixOS module

The flake provides `nixosModules.telltale` and an overlay that adds `pkgs.telltale`.

## Quick start

```nix
{
  inputs.telltale.url = "github:paimonsoror/telltaledns";

  outputs = { self, nixpkgs, telltale }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        telltale.nixosModules.telltale
        {
          services.telltale.enable = true;
          services.telltale.openFirewall = true;
        }
      ];
    };
  };
}
```

This installs the binary, creates a `telltale` user, writes `/etc/telltale/telltale.toml`,
and starts a hardened systemd service that listens on UDP and TCP port 53.

The module supplies sensible defaults (Cloudflare and Quad9 over TLS, Hagezi Pro
blocklist, 7-day query-log retention). Override them with `services.telltale.settings`.

## Web UI

The default package ships without the web UI (the API still works). To embed the UI,
set:

```nix
services.telltale.withUi = true;
```

This builds the Svelte app from `ui/` and packages a `telltale-with-ui` binary. The
UI is then served at `/` on the API listener.

## Custom configuration

```nix
services.telltale.settings = {
  upstream = [
    { name = "cloudflare"; url = "tls://1.1.1.1:853"; tls_server_name = "cloudflare-dns.com"; }
  ];
  upstream_group = [ { name = "default"; members = [ "cloudflare" ]; strategy = "fastest"; } ];
  telemetry.qlog.retention_days = 14;
  api.listen = "0.0.0.0:8053";
};
```

Use `services.telltale.configFile` to point to an existing TOML file instead.

## Bootstrap admin

Create the first admin from a secret without putting credentials in the Nix store:

```nix
services.telltale.bootstrapAdmin = {
  user = "admin";
  passwordHashFile = "/run/secrets/telltale-admin-hash";
};
```

Generate the hash with `telltale auth hash-password`. The file is passed to the
service as a systemd credential.

## systemd-resolved

If port 53 is already held by `systemd-resolved`, set:

```nix
services.telltale.disableResolvedStub = true;
```

This writes `DNSStubListener=no` to the resolved configuration.

## Tailscale device names

TelltaleDNS can read the local `tailscaled` peer list and name Tailscale devices
by their host names:

```nix
services.telltale.settings.router = [
  { name = "tailnet"; type = "tailscale"; }
];

# If you use a non-standard socket path:
# { name = "tailnet"; type = "tailscale"; socket_path = "/run/tailscale/tailscaled.sock"; }
```

The module automatically adds the `telltale` user to the `tailscale` group so it
can reach `tailscaled.sock`. Tailscale must be enabled separately (`services.tailscale.enable = true`).
Discovered peers show up in the web UI at **Clients → Discovered**, with the router name as their source.

## Cluster

The module can configure a cluster declaratively using TelltaleDNS's automatic
bootstrap options (`[cluster.init]` and `[cluster.join_url]`). The shared secret
is passed as a systemd credential, so it never enters the Nix store.

Generate or provision the same secret file on every node (for example with
[sops-nix](https://github.com/Mic92/sops-nix)):

```nix
sops.secrets.telltale-bootstrap-secret = {
  sopsFile = ./secrets/telltale.yaml;
  owner = config.services.telltale.user;
};
```

### Primary

The primary creates the cluster on first start and owns the shared configuration:

```nix
services.telltale = {
  enable = true;
  openFirewall = true;

  cluster = {
    enable = true;
    role = "primary";
    name = "home";
    site = "livingroom";
    advertise = [ "https://192.168.1.2:8443" ];
    bootstrapSecretFile = config.sops.secrets.telltale-bootstrap-secret.path;
  };

  # shared configuration — replicas will receive all of this
  settings = {
    upstream = [
      { name = "cloudflare"; url = "tls://1.1.1.1:853"; tls_server_name = "cloudflare-dns.com"; }
    ];
    upstream_group = [ { name = "default"; members = [ "cloudflare" ]; strategy = "fastest"; } ];
    group = [ { name = "default"; lists = [ "hagezi-pro" ]; } ];
  };
};
```

### Replica

The replica joins the primary on first start using the same bootstrap secret:

```nix
services.telltale = {
  enable = true;
  openFirewall = true;

  cluster = {
    enable = true;
    role = "replica";
    name = "home";
    site = "office";
    joinUrl = "https://192.168.1.2:8443";
    bootstrapSecretFile = config.sops.secrets.telltale-bootstrap-secret.path;
  };

  # shared sections are ignored once joined; leave settings at the defaults
  # or override only per-node sections like [node] and [[listen]].
};
```

Notes:
- The cluster replication port (`8443/tcp`) is opened automatically when clustering is enabled.
- Two nodes alone cannot do automatic failover. Add a small witness node or a third eligible node, or promote the replica manually with `telltale cluster promote` if the primary fails.
- Set `cluster.configAuthority = "gitops"` and `settings.cluster.git` to keep the shared configuration in a Git repository instead of the primary's NixOS config.
