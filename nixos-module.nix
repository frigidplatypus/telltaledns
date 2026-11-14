{ self }:
{ config, lib, pkgs, ... }:

let
  cfg = config.services.telltale;
  settingsFormat = pkgs.formats.toml { };

  configFile =
    if cfg.configFile != null
    then cfg.configFile
    else settingsFormat.generate "telltale.toml" effectiveSettings;

  effectiveSettings = lib.recursiveUpdate {
    config_version = 1;
    node.data_dir = cfg.dataDir;
  } cfg.settings;

  isDefaultDataDir = cfg.dataDir == "/var/lib/telltale";

  loadCredentials =
    lib.optional (cfg.bootstrapAdmin.passwordFile != null)
      "admin-password:${cfg.bootstrapAdmin.passwordFile}"
    ++ lib.optional (cfg.bootstrapAdmin.passwordHashFile != null)
      "admin-password-hash:${cfg.bootstrapAdmin.passwordHashFile}";

  needsBootstrapCredentials =
    cfg.bootstrapAdmin.user != null
    && (cfg.bootstrapAdmin.passwordFile != null || cfg.bootstrapAdmin.passwordHashFile != null);

  bootstrapWrapper = pkgs.writeShellScript "telltale-run" (''
    set -eu
  '' + lib.optionalString (cfg.bootstrapAdmin.user != null) ''
    export TELLTALE_BOOTSTRAP_ADMIN_USER=${lib.escapeShellArg cfg.bootstrapAdmin.user}
  '' + lib.optionalString (cfg.bootstrapAdmin.passwordFile != null) ''
    export TELLTALE_BOOTSTRAP_ADMIN_PASSWORD="$(cat "''${CREDENTIALS_DIRECTORY}/admin-password")"
  '' + lib.optionalString (cfg.bootstrapAdmin.passwordHashFile != null) ''
    export TELLTALE_BOOTSTRAP_ADMIN_PASSWORD_HASH="$(cat "''${CREDENTIALS_DIRECTORY}/admin-password-hash")"
  '' + ''
    exec ${lib.escapeShellArg cfg.package}/bin/telltale run -c ${lib.escapeShellArg configFile} "$@"
  '');
in

{
  options.services.telltale = {
    enable = lib.mkEnableOption "TelltaleDNS filtering DNS resolver";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.system}.default;
      defaultText = lib.literalExpression "self.packages.${pkgs.system}.default";
      description = "The TelltaleDNS package to use.";
    };

    configFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to a static `telltale.toml`. When null, the module generates the config from
        `services.telltale.settings`.
      '';
    };

    settings = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {
        upstream = [
          {
            name = "cloudflare";
            url = "tls://1.1.1.1:853";
            tls_server_name = "cloudflare-dns.com";
          }
          {
            name = "quad9";
            url = "tls://9.9.9.9:853";
            tls_server_name = "dns.quad9.net";
          }
        ];
        upstream_group = [
          {
            name = "default";
            members = [ "cloudflare" "quad9" ];
            strategy = "fastest";
          }
        ];
        list = [
          {
            name = "hagezi-pro";
            url = "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/pro.txt";
          }
        ];
        telemetry.qlog.retention_days = 7;
      };
      description = ''
        TelltaleDNS configuration written to `/etc/telltale/telltale.toml`.
        See `docs/configuration.md` for the full schema.
      '';
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/telltale";
      description = "Directory for TelltaleDNS state, query logs, and certificates.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "telltale";
      description = "User the TelltaleDNS service runs as.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "telltale";
      description = "Group the TelltaleDNS service runs as.";
    };

    createUser = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to create the configured user and group.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open ports 53/udp and 53/tcp in the firewall.";
    };

    extraFirewallPorts = lib.mkOption {
      type = lib.types.listOf lib.types.port;
      default = [ ];
      description = "Additional TCP/UDP ports to open when `openFirewall` is enabled.";
    };

    disableResolvedStub = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Disable systemd-resolved's DNS stub listener (`DNSStubListener=no`).
        Enable this when TelltaleDNS binds port 53 and resolved already holds it.
      '';
    };

    bootstrapAdmin = {
      user = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Username for the first admin account created on a fresh install.";
      };

      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Path to a file containing the first admin's plain-text password.
          Passed to the service as a systemd credential.
        '';
      };

      passwordHashFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Path to a file containing an Argon2id PHC hash for the first admin.
          Generate it with `telltale auth hash-password`. Passed as a systemd credential.
        '';
      };
    };

    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Extra environment variables for the TelltaleDNS service.";
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra arguments appended to `telltale run`.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.bootstrapAdmin.passwordFile == null || cfg.bootstrapAdmin.passwordHashFile == null;
        message = "services.telltale.bootstrapAdmin: set at most one of passwordFile and passwordHashFile.";
      }
    ];

    users.users = lib.mkIf cfg.createUser {
      ${cfg.user} = {
        isSystemUser = true;
        inherit (cfg) group;
        home = cfg.dataDir;
        description = "TelltaleDNS service user";
      };
    };

    users.groups = lib.mkIf cfg.createUser {
      ${cfg.group} = { };
    };

    environment.etc."telltale/telltale.toml".source = configFile;

    systemd.services.telltale = {
      description = "TelltaleDNS resolver";
      documentation = [ "https://github.com/paimonsoror/telltaledns/blob/main/docs/running.md" ];
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        ExecStart =
          if needsBootstrapCredentials
          then "${bootstrapWrapper} ${lib.escapeShellArgs cfg.extraArgs}"
          else "${cfg.package}/bin/telltale run -c ${configFile} ${lib.escapeShellArgs cfg.extraArgs}";
        ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
        Restart = "on-failure";
        RestartSec = 2;
        TimeoutStopSec = 30;
        UMask = "0027";
        Environment =
          [ "TELLTALE_INSTALL=native" ]
          ++ lib.optional (cfg.bootstrapAdmin.user != null && !needsBootstrapCredentials)
            "TELLTALE_BOOTSTRAP_ADMIN_USER=${cfg.bootstrapAdmin.user}"
          ++ lib.mapAttrsToList (k: v: "${k}=${v}") cfg.environment;

        AmbientCapabilities = "CAP_NET_BIND_SERVICE";
        CapabilityBoundingSet = "CAP_NET_BIND_SERVICE";
        NoNewPrivileges = true;

        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        ProtectProc = "invisible";
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        RemoveIPC = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [ "@system-service" "~@privileged" ];
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" "AF_NETLINK" ];
        MemoryMax = "256M";
        LimitNOFILE = 65536;
      }
      // lib.optionalAttrs isDefaultDataDir {
        StateDirectory = "telltale";
        StateDirectoryMode = "0750";
      }
      // lib.optionalAttrs (!isDefaultDataDir) {
        ReadWritePaths = [ cfg.dataDir ];
      }
      // lib.optionalAttrs (loadCredentials != [ ]) {
        LoadCredential = loadCredentials;
      };
    };

    systemd.tmpfiles.rules = lib.optional (!isDefaultDataDir)
      "d ${cfg.dataDir} 0750 ${cfg.user} ${cfg.group} -";

    networking.firewall = lib.mkIf cfg.openFirewall {
      allowedUDPPorts = [ 53 ] ++ cfg.extraFirewallPorts;
      allowedTCPPorts = [ 53 ] ++ cfg.extraFirewallPorts;
    };

    services.resolved.extraConfig = lib.mkIf cfg.disableResolvedStub "DNSStubListener=no\n";
  };
}
