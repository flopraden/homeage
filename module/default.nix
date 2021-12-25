{ pkgs, config, options, lib, ... }:
with lib;

let
  cfg = config.homeage;

  # All files are decrypted to /run/user and cleaned up when rebooted
  runtimeDecryptFolder = cfg.mount;

  ageBin = if cfg.isRage then "${cfg.pkg}/bin/rage" else "${cfg.pkg}/bin/age";

  runtimeDecryptPath = path: runtimeDecryptFolder + "/" + path;

  identities = builtins.concatStringsSep " " (map (path: "-i ${path}") cfg.identityPaths);

  createFiles = command: runtimepath: destinations: builtins.concatStringsSep "\n" ((map (dest: ''
    $DRY_RUN_CMD mkdir $VERBOSE_ARG -p $(dirname ${dest})
    $DRY_RUN_CMD ${command} $VERBOSE_ARG ${runtimepath} ${dest}
  '')) destinations);

  decryptSecret = name: { file, path, symlinks, cpOnService, mode, owner, group, ... }:
    let
      runtimepath = runtimeDecryptPath path;
      linksCmds = createFiles "ln -sf" runtimepath symlinks;
      copiesCmds = createFiles "cp -f" runtimepath cpOnService;
    in
    ''
      echo "Decrypting secret ${file} to ${runtimepath}"
      TMP_FILE="${runtimepath}.tmp"
      $DRY_RUN_CMD mkdir $VERBOSE_ARG -p $(dirname ${runtimepath})
      (
        $DRY_RUN_CMD umask u=r,g=,o=
        $DRY_RUN_CMD ${ageBin} -d ${identities} -o "$TMP_FILE" "${file}"
      )
      $DRY_RUN_CMD chmod $VERBOSE_ARG ${mode} "$TMP_FILE"
      $DRY_RUN_CMD chown $VERBOSE_ARG ${owner}:${group} "$TMP_FILE"
      $DRY_RUN_CMD mv $VERBOSE_ARG -f "$TMP_FILE" "${runtimepath}"
      ${linksCmds}
      ${copiesCmds}
    '';

  aSecrets = lib.attrsets.filterAttrs
     (n: v: (v.installationType == "activation") || ( (cfg.installationType == "activation") && (v.installationType == "global") )
     cfg.secrets;
  sSecrets = lib.attrsets.filterAttrs
     (n: v: (v.installationType == "service") || ( (cfg.installationType == "service") && (v.installationType == "global") )
     cfg.secrets;

  activationScript = builtins.concatStringsSep "\n" (lib.attrsets.mapAttrsToList decryptSecret aSecrets);

  mkServices = lib.attrsets.mapAttrs'
    (name: value:
      lib.attrsets.nameValuePair
        ("${name}-secret")
        ({
          Unit = {
            Description = "Decrypt ${name} secret";
          };

          Service = {
            Type = "oneshot";
            ExecStart = "${pkgs.writeShellScript "${name}-decrypt" ''
              set -euo pipefail
              DRY_RUN_CMD=
              VERBOSE_ARG=

              ${decryptSecret name value}
            ''}";
            Environment = "PATH=${makeBinPath [ pkgs.coreutils ]}";
          };

          Install = {
            WantedBy = [ "default.target" ];
          };
        })
    )
    sSecrets;

  # Options for a secret file
  # Based on https://github.com/ryantm/agenix/pull/58
  secretType = types.submodule ({ name, ... }: {
    options = {
      file = mkOption {
        description = "Path to the age encrypted file";
        type = types.path;
      };

      path = mkOption {
        description = "Relative path of where the file will be saved in /run";
        type = types.str;
      };

      mode = mkOption {
        type = types.str;
        default = "0400";
        description = "Permissions mode of the decrypted file";
      };

      owner = mkOption {
        type = types.str;
        default = "$UID";
        description = "User of the decrypted file";
      };

      group = mkOption {
        type = types.str;
        default = "$(id -g)";
        description = "Group of the decrypted file";
      };

      symlinks = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Symbolically link decrypted file to absolute paths";
      };

      cpOnService = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Copy decrypted file to absolute paths";
      };

      installationType = mkOption {
        description = ''
          Specify the way how secrets should be installed. Either via systemd user services (<literal>service</literal>)
          or during the activation of the generation (<literal>activation</literal>).
	  By default, <literal>activation</literal> is to use the <literal>homeage.installationType</literal> config
	  in global homeage configuration.
          </para><para>
          Note: Keep in mind that symlinked secrets will not work after reboots with <literal>activation</literal> if
          <literal>homeage.mount</literal> does not point to persistent location.
        '';
        default = "global";
        type = types.enum [ "global" "activation" "service" ];
      };
    };

    config = {
      path = mkDefault name;
    };
  });
in
{
  options.homeage = {
    secrets = mkOption {
      description = "Attrset of secrets";
      default = { };
      type = types.attrsOf secretType;
    };

    pkg = mkOption {
      description = "(R)age package to use";
      default = pkgs.age;
      type = types.package;
    };

    isRage = mkOption {
      description = "Is rage package";
      default = false;
      type = types.bool;
    };

    mount = mkOption {
      description = "Absolute path to folder where decrypted files are stored. Files are decrypted on login. Defaults to /run which is a tmpfs.";
      default = "/run/user/$UID/secrets";
      type = types.str;
    };

    identityPaths = mkOption {
      description = "Absolute path to identity files used for age decryption. Must provide at least one path";
      default = [ ];
      type = types.listOf types.str;
    };

    installationType = mkOption {
      description = ''
        Specify the way how secrets should be installed. Either via systemd user services (<literal>service</literal>)
        or during the activation of the generation (<literal>activation</literal>).
        </para><para>
        Note: Keep in mind that symlinked secrets will not work after reboots with <literal>activation</literal> if
        <literal>homeage.mount</literal> does not point to persistent location.
      '';
      default = "service";
      type = types.enum [ "activation" "service" ];
    };
  };

  config = mkIf (cfg.secrets != { }) (mkMerge [
    {
      assertions = [{
        assertion = cfg.identityPaths != [ ];
        message = "secret.identityPaths must be set.";
      }];

      home.activation = mkIf (aSecrets != { }) {
        homeage = hm.dag.entryAfter [ "writeBoundary" ] activationScript;
      };

      systemd.user.services = mkIf (sSecrets != { }) mkServices;
    }
  ]);
}
