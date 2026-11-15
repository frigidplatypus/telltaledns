{ self }:
{ config, lib, pkgs, ... }:

let
  cfg = config.services.telltale;
  settingsFormat = pkgs.formats.toml { };

  configFile =
    if cfg.configFile != null
    then cfg.configFile
    else settingsFormat.generate "telltale.toml" effectiveSettings;

  clusterListen = "${cfg.cluster.listenAddress}:${toString cfg.cluster.port}";

  clusterBase = lib.optionalAttrs cfg.cluster.enable {
    cluster = {
      name = cfg.cluster.name;
      site = cfg.cluster.site;
      listen = clusterListen;
      eligible = cfg.cluster.eligible;
      config_source = if cfg.cluster.configAuthority == "gitops" then "gitops" else "file";
    }
    // lib.optionalAttrs (cfg.cluster.bootstrapSecretFile != null) {
      bootstrap_secret_file = "/run/credentials/telltale.service/bootstrap-secret";
    }
    // lib.optionalAttrs (cfg.cluster.role == "primary") {
      init = {
        advertise = cfg.cluster.advertise;
        config_authority = cfg.cluster.configAuthority;
      };
    }
    // lib.optionalAttrs (cfg.cluster.role == "replica") {
      join_url = cfg.cluster.joinUrl;
      ephemeral = cfg.cluster.ephemeral;
    };
  };

  effectiveSettings = lib.recursiveUpdate ({
    config_version = 1;
    node.data_dir = cfg.dataDir;
  } // clusterBase) cfg.settings;

  isDefaultDataDir = cfg.dataDir == "/var/lib/telltale";

  loadCredentials =
    lib.optional (cfg.cluster.bootstrapSecretFile != null)
      "bootstrap-secret:${cfg.cluster.bootstrapSecretFile}"
    ++ lib.optional (cfg.bootstrapAdmin.passwordFile != null)
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

    cluster = {
      enable = lib.mkEnableOption "TelltaleDNS cluster membership";

      name = lib.mkOption {
        type = lib.types.str;
        default = "telltale";
        description = "Cluster name.";
      };

      site = lib.mkOption {
        type = lib.types.str;
        default = config.networking.hostName;
        description = "Site label for this node (shown in the cluster UI).";
      };

      role = lib.mkOption {
        type = lib.types.enum [ "primary" "replica" ];
        default = "primary";
        description = ''
          Whether this node creates the cluster (`primary`) or joins an existing
          one (`replica`).
        '';
      };

      listenAddress = lib.mkOption {
        type = lib.types.str;
        default = "0.0.0.0";
        description = "Address the cluster replication port listens on.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 8443;
        description = "Cluster replication port.";
      };

      advertise = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          URLs other nodes use to reach this primary. Required when `role` is
          `primary`.
        '';
      };

      joinUrl = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Primary URL a replica joins (`https://primary:8443`). Required when
          `role` is `replica`.
        '';
      };

      bootstrapSecretFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Path to a shared secret used for declarative joining. It is passed to
          the service as a systemd credential. Must be the same file on every
          node. Use at least 32 random characters.
        '';
      };

      eligible = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether this node may be promoted to primary. Ephemeral replicas
          should set this to false.
        '';
      };

      ephemeral = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Join as an ephemeral member (never primary, never a voter). Use for
          resolver-only replicas.
        '';
      };

      configAuthority = lib.mkOption {
        type = lib.types.enum [ "api" "gitops" ];
        default = "api";
        description = ''
          Where the cluster's shared configuration comes from. `api` means the
          primary's own file/UI; `gitops` means a Git repository configured in
          `services.telltale.settings.cluster.git`.
        '';
      };
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
      {
        assertion = !cfg.cluster.enable || cfg.cluster.role == "replica" || cfg.cluster.advertise != [ ];
        message = "services.telltale.cluster.advertise must contain at least one URL when role is primary.";
      }
      {
        assertion = !cfg.cluster.enable || cfg.cluster.role == "primary" || cfg.cluster.joinUrl != null;
        message = "services.telltale.cluster.joinUrl is required when role is replica.";
      }
      {
        assertion = !cfg.cluster.enable || cfg.cluster.role == "primary" || cfg.cluster.bootstrapSecretFile != null;
        message = "services.telltale.cluster.bootstrapSecretFile is required when role is replica.";
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
      allowedTCPPorts = [ 53 ] ++ cfg.extraFirewallPorts ++ lib.optional cfg.cluster.enable cfg.cluster.port;
    };

    services.resolved.extraConfig = lib.mkIf cfg.disableResolvedStub "DNSStubListener=no\n";
  };
}
