# Reusable home-manager module: image builders for environments WITHOUT
# enough privileges for Docker or podman -- a notebook or IDE container
# (JupyterHub, Coder, a CI pod, ...) with no container daemon, no user
# namespaces and no CAP_SYS_ADMIN, where `sudo` (chroot, mknod) still works.
#
#   kaniko-build   kaniko in a disposable chroot; a clean build every time
#   buildah-build  a patched buildah in a persistent chroot; keeps its layer cache
#
# Plain nix-built wrapped scripts on PATH. The scripts shell out to host
# `sudo`/`chroot`/`mknod` (kept on PATH after the pinned nix deps) and download
# their executor / rootfs images at runtime into ~/.local/share (external OCI
# images, not nix-store material). See docs/builders/.
#
# With it come the cluster tools that make sense off the cluster too
# (`package`, `slurm-cache`, `slurm-monitor`), so a dev loop in the pod reads
# what CI published, and profiles a run, the same way a CI job does.
{ pkgs, lib, config, ... }:
let
  cfg = config.programs.restrictedBuilders;

  # Wrap a checked-in builder script: copy it, patch its shebang to nixpkgs
  # bash, and prepend pinned tool deps to PATH. Host sudo/chroot/mknod still
  # resolve (they're not in the nix deps, so they come from the ambient PATH
  # after the prefix).
  wrapBuilder = { name, src, deps }:
    pkgs.runCommandLocal name { nativeBuildInputs = [ pkgs.makeWrapper ]; } ''
      mkdir -p $out/bin
      cp ${src} $out/bin/${name}
      chmod +x $out/bin/${name}
      patchShebangs $out/bin/${name}
      wrapProgram $out/bin/${name} \
        --prefix PATH : ${lib.makeBinPath deps}
    '';

  # The cluster tools a CI job uses on the login node that make sense off it
  # too (slurm/): `package` (one file in a package registry), `slurm-cache`
  # (big artifacts as parts plus a manifest, fetched verified) and
  # `slurm-monitor` (a job's resource profile; here it samples a local
  # process tree). Plain scripts -- nothing compiles.
  cluster-tools = let src = ../../slurm; in
    pkgs.runCommandLocal "cluster-tools" { nativeBuildInputs = [ pkgs.makeWrapper ]; } ''
      d=$out/share/cluster-tools
      mkdir -p $d/bin $d/lib $out/bin
      cp ${src}/lib/registry.sh ${src}/lib/dispatch.sh ${src}/lib/config.sh $d/lib/
      cp -r ${src}/monitor $d/monitor
      for t in package slurm-cache slurm-monitor; do
        cp ${src}/bin/$t $d/bin/$t
        chmod +x $d/bin/$t
        patchShebangs $d/bin/$t
        makeWrapper $d/bin/$t $out/bin/$t \
          --prefix PATH : ${lib.makeBinPath (with pkgs; [ curl python3 gnutar gzip coreutils ])}
      done
    '';

  kaniko-build = wrapBuilder {
    name = "kaniko-build";
    src = ../../builders/kaniko/kaniko-build.sh;
    deps = with pkgs; [ curl python3 jq rsync gnutar gzip coreutils gnused ];
  };

  # --- buildah (docs/builders/buildah.md) -------------------------------------
  #
  # buildah v1.41.5 with builders/buildah/buildah-restricted.patch, compiled
  # here: no binary cache has it. Pure Go, about two minutes.
  #
  # Two things are not negotiable:
  #  - STATIC. The binary runs inside the Fedora rootfs that buildah-build
  #    chroots into, where /nix/store does not exist; a nix-linked binary would
  #    find neither its interpreter nor its libc.
  #  - NO TESTS (doCheck = false). Faster, and no Go *.test binaries land on a
  #    shared host, where endpoint-security scanners tend to flag them.
  buildah-restricted = pkgs.buildGoModule {
    pname = "buildah-restricted";
    version = "1.41.5";
    # Nix's own fetcher, not fetchFromGitHub: where nix-portable runs
    # builders under proot, whose tar fails on the symlinks in buildah's test
    # data ("Cannot change mode ... No such file or directory").
    src = builtins.fetchTarball {
      url = "https://github.com/containers/buildah/archive/refs/tags/v1.41.5.tar.gz";
      sha256 = "sha256-NQ5nCU1uiw3SzPMo2rH4+GnAIbIzM9O0bJaXJg/rfZM=";
    };
    # The default unpack copies the tree with its permissions, which proot
    # cannot set either ("cp: setting permissions for 'source'"). Copy without
    # them; tests/ (fixtures with dangling symlinks) is not built anyway.
    unpackPhase = ''
      runHook preUnpack
      mkdir source
      cp -r --no-preserve=mode,ownership,timestamps $(ls -A -d $src/* $src/.[!.]* 2>/dev/null | grep -v '/tests$') source/
      chmod -R u+w source
      cd source
      runHook postUnpack
    '';
    patches = [
      ../../builders/buildah/buildah-restricted.patch
      ../../builders/buildah/buildah-restricted-nocgo.patch
    ];
    vendorHash = null;              # buildah vendors its dependencies
    subPackages = [ "cmd/buildah" ];
    # The build tags of the hand-built binary: no gpgme, btrfs or
    # devicemapper, so nothing to link but libc.
    tags = [ "containers_image_openpgp" "exclude_graphdriver_btrfs" "exclude_graphdriver_devicemapper" ];
    # Pure Go: static by construction, and no gcc. A cgo build cannot be done
    # under proot: Go starts gcc with clone(CLONE_VM|CLONE_VFORK), and every
    # cgo compile failed with "Bad address" (even -p=1, even without proot's
    # seccomp mode). The C it drops is containers/storage's unshare.c
    # constructor; buildah-restricted-nocgo.patch does its part of the handshake in Go
    # -- without it every RUN step failed with 'parsing PID ""'.
    env.CGO_ENABLED = "0";
    ldflags = [ "-s" "-w" ];
    doCheck = false;
    # Go under proot: every async-preemption signal and every thread switch
    # is a ptrace stop, and with GOMAXPROCS = the host's cores (72) the
    # compiler spent 19 minutes in system time on encoding/binary.
    #
    # nix-portable builds without a sandbox there, so $HOME is the real
    # /homeless-shelter path: Go created it (telemetry), and nix then refused
    # every later build ("home directory '/homeless-shelter' exists").
    preConfigure = ''
      export HOME=$TMPDIR GOTELEMETRY=off
    '';
    preBuild = ''
      export GODEBUG=asyncpreemptoff=1 GOMAXPROCS=4
    '';
  };

  # fakemount-simple (the seccomp filter) and buildah-wrap (HOME for buildah's
  # re-exec), static for the same reason. Two small C files.
  buildah-restricted-helpers = pkgs.runCommandCC "buildah-restricted-helpers" { buildInputs = [ pkgs.glibc.static ]; } ''
    mkdir -p $out/bin
    $CC -static -O2 -o $out/bin/fakemount-simple ${../../builders/buildah/fakemount-simple.c}
    $CC -static -O2 -o $out/bin/buildah-wrap ${../../builders/buildah/buildah-wrap.c}
  '';

  buildah-build = pkgs.runCommandLocal "buildah-build" { nativeBuildInputs = [ pkgs.makeWrapper ]; } ''
    mkdir -p $out/bin
    cp ${../../builders/buildah/buildah-build.sh} $out/bin/buildah-build
    chmod +x $out/bin/buildah-build
    patchShebangs $out/bin/buildah-build
    wrapProgram $out/bin/buildah-build \
      --set BUILDAH_PATCHED ${buildah-restricted}/bin/buildah \
      --set FAKEMOUNT_BIN ${buildah-restricted-helpers}/bin/fakemount-simple \
      --set WRAPPER_BIN ${buildah-restricted-helpers}/bin/buildah-wrap \
      --prefix PATH : ${lib.makeBinPath (with pkgs; [ crane gnutar coreutils diffutils python3 ])}
  '';
in {
  options.programs.restrictedBuilders = {
    enable = lib.mkEnableOption ''
      image builders for environments without enough privileges for Docker
      or podman (kaniko-build, buildah-build; they need sudo), plus the
      package / slurm-cache / slurm-monitor tools'';
    buildah.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Install buildah-build. Its patched buildah is compiled on the first
        switch (pure Go, a few minutes); set false for kaniko-build only.
      '';
    };
    dockerHubMirror = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "mirror.example.org:5000";
      description = ''
        host[:port] of a Docker Hub pull-through cache both builders pull
        docker.io images through (DOCKER_HUB_MIRROR). null: Docker Hub itself.
      '';
    };
    gitlabUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "https://gitlab.example.org";
      description = "The GitLab that package / slurm-cache talk to outside CI (GITLAB_URL).";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ kaniko-build cluster-tools ] ++ lib.optional cfg.buildah.enable buildah-build;
    home.sessionVariables =
      lib.optionalAttrs (cfg.dockerHubMirror != null) { DOCKER_HUB_MIRROR = cfg.dockerHubMirror; }
      // lib.optionalAttrs (cfg.gitlabUrl != null) { GITLAB_URL = cfg.gitlabUrl; };
  };
}
