{
  description = "GitLab CI on SLURM: a shell runner on the login node, jobs on the compute nodes, rootless BuildKit image builds";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, home-manager, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      lib = nixpkgs.lib;

      # A standalone home-manager configuration. With `impure`, the user, the
      # home and your settings come from the environment at switch time:
      # $USER, $HOME and ~/.config/slurm-gitlab-ci/local.nix (or
      # $SLURM_CI_LOCAL_NIX) -- outside the checkout, so a `git pull` never
      # touches them. See local.example.nix.
      mkHome = { flakeAttr, modules, user ? null, homeDir ? null }:
        let
          env = builtins.getEnv;
          username = if user != null then user else env "USER";
          homeDirectory = if homeDir != null then homeDir else env "HOME";
          localNix =
            let p = if env "SLURM_CI_LOCAL_NIX" != "" then env "SLURM_CI_LOCAL_NIX"
                    else "${homeDirectory}/.config/slurm-gitlab-ci/local.nix";
            in lib.optional (user == null && builtins.pathExists p) (/. + p);
        in
        assert lib.assertMsg (username != "" && homeDirectory != "")
          "homeConfigurations.${flakeAttr} reads $USER and $HOME: evaluate it with --impure (hm-switch does).";
        home-manager.lib.homeManagerConfiguration {
          inherit pkgs;
          modules = modules ++ localNix ++ [
            ./nix/modules/hm-switch.nix
            {
              home = {
                inherit username homeDirectory;
                stateVersion = "25.11";
              };
              programs.hmSwitch = {
                enable = lib.mkDefault true;
                repoDir = lib.mkDefault (let d = env "SLURM_CI_REPO_DIR"; in if d != "" then d else "$HOME/slurm-gpu-for-gitlab-ci");
                inherit flakeAttr;
              };
            }
          ];
        };

      # The configurations the checks build: fixed user, everything on.
      testUser = { user = "ci"; homeDir = "/home/ci"; };
      testSite = {
        services.slurmCi = { gitlabUrl = "https://gitlab.example.org"; partition = "gpu"; };
        services.buildkitSlurm = { enable = true; node = "node1"; registryMirrors = [ "mirror.example.org:5000" ]; };
        services.gitlabRunnerSlurm = {
          enable = true;
          runners."42" = { name = "ci_on_slurm"; extraTags = [ "gpu" ]; };
        };
      };
    in {
      homeManagerModules = {
        slurm-runner = ./nix/modules/slurm-runner.nix;
        restricted-builders = ./nix/modules/restricted-builders.nix;
        hm-switch = ./nix/modules/hm-switch.nix;
        default = ./nix/modules/slurm-runner.nix;
      };

      # `hm-switch` (or the first switch in bootstrap/install.sh) picks one:
      #   slurm-frontend    the SLURM login node: runner, BuildKit, slurm-* tools
      #   restricted-pod    a container without Docker/podman privileges
      #                     (kaniko-build, buildah-build; needs sudo)
      homeConfigurations = {
        slurm-frontend = mkHome {
          flakeAttr = "slurm-frontend";
          modules = [ ./nix/modules/slurm-runner.nix ];
        };
        restricted-pod = mkHome {
          flakeAttr = "restricted-pod";
          modules = [ ./nix/modules/restricted-builders.nix { programs.restrictedBuilders.enable = true; } ];
        };
      };

      checks.${system} = {
        # The whole frontend configuration builds (all options on).
        slurm-frontend = (mkHome (testUser // {
          flakeAttr = "slurm-frontend";
          modules = [ ./nix/modules/slurm-runner.nix testSite ];
        })).activationPackage;
        # The restricted builders without the from-source buildah, which
        # takes minutes; `nix build .#restricted-builders` builds that one too.
        restricted-pod = (mkHome (testUser // {
          flakeAttr = "restricted-pod";
          modules = [ ./nix/modules/restricted-builders.nix {
            programs.restrictedBuilders = { enable = true; buildah.enable = false; };
          } ];
        })).activationPackage;

        shellcheck = pkgs.runCommandLocal "shellcheck" { nativeBuildInputs = [ pkgs.shellcheck ]; } ''
          cd ${self}
          shellcheck -S warning -x \
            slurm/bin/* slurm/lib/*.sh slurm/*.sh \
            builders/kaniko/*.sh builders/buildah/*.sh bootstrap/*.sh
          touch $out
        '';

        pytest = let py = pkgs.python3.withPackages (ps: [ ps.pytest ps.pyyaml ps.matplotlib ]); in
          pkgs.runCommandLocal "pytest" {
          nativeBuildInputs = [ py pkgs.bash pkgs.coreutils pkgs.gnugrep pkgs.gawk ];
        } ''
          # No permissions copied (proot cannot set them), and the env's
          # site-packages named explicitly (under proot the env's symlinked
          # python resolves to the bare interpreter).
          mkdir slurm && cp -r --no-preserve=mode,ownership,timestamps ${self}/slurm/* slurm/
          chmod -R u+w slurm && chmod +x slurm/bin/* slurm/*.sh slurm/*.py
          patchShebangs slurm
          export HOME=$TMPDIR MPLBACKEND=Agg OPENBLAS_NUM_THREADS=4
          export PYTHONPATH=${py}/${py.sitePackages}
          python3 -m pytest -q -p no:cacheprovider slurm/tests slurm/monitor/tests
          touch $out
        '';
      };

      packages.${system}.restricted-builders =
        let hm = mkHome (testUser // {
              flakeAttr = "restricted-pod";
              modules = [ ./nix/modules/restricted-builders.nix { programs.restrictedBuilders.enable = true; } ];
            });
        in pkgs.buildEnv {
          name = "restricted-builders";
          paths = hm.config.home.packages;
        };

      formatter.${system} = pkgs.nixfmt;
    };
}
