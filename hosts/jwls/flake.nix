{
  description = "A flake for building my NUR packages on J.W.LS";

  # To update all inputs:
  # $ nix flake update --recreate-lock-file
  inputs = {
    nixpkgs.url          = "github:dguibert/nixpkgs/pu-cluster"; # autogen> RPATH of binary /p/home/jusers/guibert1/shared/nix/store/sz2zsddmdxznnrgrbqi5wygbyv4dxcp9-autogen-5.18.16-bin/bin/columns contains a forbidden reference to /tmp/nix-build-autogen-5.18.16.drv-0/

    nix.url              = "github:dguibert/nix/pu";
    nix.inputs.nixpkgs.follows = "nixpkgs";

    flake-utils.url = "github:numtide/flake-utils";

    home-manager. url    = "github:dguibert/home-manager/pu";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    base16-nix           = { url  = "github:atpotts/base16-nix"; flake=false; };
    # For accessing `deploy-rs`'s utility Nix functions
    deploy-rs.url = "github:serokell/deploy-rs";
    deploy-rs.inputs.nixpkgs.follows = "nixpkgs";

    nxsession.url              = "github:dguibert/nxsession";
  };

  outputs = { self, nixpkgs
            , nix
            , flake-utils
            , home-manager
            , base16-nix
            , deploy-rs
            , nxsession
            }@flakes: let

      # Memoize nixpkgs for different platforms for efficiency.
      defaultPkgsFor = system:
        import nixpkgs {
          inherit system;
          overlays =  [
            overlays.default
            nix.overlay
            (final: prev: {
              nixStore = (self.overlay final prev).nixStore;
            })
          ];
          config.allowUnfree = true;
        };
      nixpkgsFor = system:
        import nixpkgs {
          inherit system;
          overlays =  [
            nix.overlay
            overlays.default
            overlays.aocc
            overlays.flang
            overlays.intel-compilers
            overlays.arm
            overlays.pgi
            (import ../../envs/overlay.nix nixpkgs)
            (import ../../emacs/overlay.nix)
            self.overlay
            (final: prev: {
              pinentry = prev.pinentry.override { enabledFlavors = [ "curses" "tty" ]; };
            })
            nxsession.overlay
          ];
          config.allowUnfree = true;
        };

    overlays = import ../../overlays;

    NIX_CONF_DIR_fun = pkgs: let
      nixConf = pkgs.writeTextDir "opt/nix.conf" ''
        max-jobs = 8
        cores = 0
        sandbox = false
        auto-optimise-store = true
        require-sigs = true
        trusted-users = nixBuild dguibert
        allowed-users = *

        system-features = recursive-nix nixos-test benchmark big-parallel kvm
        sandbox-fallback = false

        keep-outputs = true       # Nice for developers
        keep-derivations = true   # Idem
        extra-sandbox-paths = /opt/intel/licenses=/home/dguibert/nur-packages/secrets?
        experimental-features = nix-command flakes ca-references recursive-nix

        #builders = @/tmp/nix--home_nfs-bguibertd-machines
      '';
    in
      "${nixConf}/opt";

  in (flake-utils.lib.eachSystem [ "x86_64-linux" ] (system:
       let pkgs = nixpkgsFor system;
           defPkgs = defaultPkgsFor system;
       in rec {

    legacyPackages = pkgs;

    defaultApp = apps.nix;
    apps.nix = flake-utils.lib.mkApp { drv = pkgs.writeScriptBin "nix-spartan" (with defPkgs; let
        name = "nix-${builtins.replaceStrings [ "/" ] [ "-" ] nixStore}";
        NIX_CONF_DIR = NIX_CONF_DIR_fun pkgs;
      # https://gist.githubusercontent.com/cleverca22/bc86f34cff2acb85d30de6051fa2c339/raw/03a36bbced6b3ae83e46c9ea9286a3015e8285ee/doit.sh
      # NIX_REMOTE=local?root=/home/clever/rootfs/
      # NIX_CONF_DIR=/home/$X/etc/nix
      # NIX_LOG_DIR=/home/$X/nix/var/log/nix
      # NIX_STORE=/home/$X/nix/store
      # NIX_STATE_DIR=/home/$X/nix/var
      # nix-build -E 'with import <nixpkgs> {}; nix.override { storeDir = "/home/'$X'/nix/store"; stateDir = "/home/'$X'/nix/var"; confDir = "/home/'$X'/etc"; }'
      in ''
        #!${runtimeShell}
        set -x
        export XDG_CACHE_HOME=$HOME/.cache/${name}
        export NIX_STORE=${nixStore}/store
        export PATH=${defPkgs.nix}/bin:$PATH
        $@
      '');
    };

    devShell = with defPkgs; mkShell rec {
      name = "nix-${builtins.replaceStrings [ "/" ] [ "-" ] nixStore}";
      ENVRC = "nix-${builtins.replaceStrings [ "/" ] [ "-" ] nixStore}";
      nativeBuildInputs = [ defPkgs.nix jq
        deploy-rs.packages.${system}.deploy-rs
      ];
      shellHook = ''
        export ENVRC=${name}
        export XDG_CACHE_HOME=$HOME/.cache/${name}
        export NIX_STORE=${nixStore}/store
        unset TMP TMPDIR TEMPDIR TEMP
        unset NIX_PATH

      '';
      NIX_CONF_DIR = NIX_CONF_DIR_fun pkgs;
    };

    homeConfigurations.home-guibert1 = home-manager.lib.homeManagerConfiguration {
      username = "guibert1";
      homeDirectory = "/p/home/jusers/guibert1/juwels";
      inherit system pkgs;
      configuration = { lib, ... }: {
        imports = [ (import "${base16-nix}/base16.nix")
          (import ./home-dguibert.nix)
        ];
        _module.args.pkgs = lib.mkForce pkgs;
      };
    };


  })) // {
    overlay = final: prev: (import ./overlay.nix final prev) //{
      nix_spartan = defaultPkgsFor.x86_64-linux.nix;
    };

    deploy.nodes.jwls = {
      hostname = "juwels-booster";
      profiles.guibert1-hm = {
        user = "guibert1";
        sshUser = "guibert1";
        path = deploy-rs.lib.x86_64-linux.activate.custom self.homeConfigurations.x86_64-linux.home-guibert1.activationPackage
               "env NIX_STATE_DIR=${self.legacyPackages.x86_64-linux.nixStore}/var/nix HOME_MANAGER_BACKUP_EXT=bak ./activate";
        profilePath = "${self.legacyPackages.x86_64-linux.nixStore}/var/nix/profiles/per-user/guibert1/hm";
      };
    };

    # This is highly advised, and will prevent many possible mistakes
    checks = builtins.mapAttrs (system: deployLib: deployLib.deployChecks self.deploy) deploy-rs.lib;
  };
}
