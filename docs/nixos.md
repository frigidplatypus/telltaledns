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

## Firewall

`services.telltale.openFirewall = true` opens port 53 on UDP and TCP. Add extra
ports (for example the API listener) with `services.telltale.extraFirewallPorts`.
