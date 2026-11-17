# Reusable home-manager module: a GitLab runner on a SLURM login node whose
# jobs run on the compute nodes, with BuildKit-over-SLURM image builds.
#
# INSTALLED ALWAYS, RUN ON OPT-IN. Importing this module installs
# gitlab-runner, the slurm-* tools and their ~/bin shims, writes the site
# settings to ~/.config/slurm-gitlab-ci/config, and starts nothing. The two
# daemons are separate switches:
#
#   services.buildkitSlurm.enable      the BuildKit daemon, a 24 h sbatch on
#                                      one compute node, renewed by cron
#   services.gitlabRunnerSlurm.enable  the gitlab-runner daemon, a systemd
#                                      --user unit with linger
#
# Site settings that every tool reads (the node, the partition, where
# node-local data lives, ...) are under services.slurmCi. See docs/setup.md.
{ pkgs, lib, config, ... }:
let
  site = config.services.slurmCi;
  cfg = config.services.gitlabRunnerSlurm;
  bk = config.services.buildkitSlurm;
  home = config.home.homeDirectory;

  # The executor every [[runners]] block this module patches uses: each job
  # runs in a shell on the login node and reaches the compute nodes through
  # slurm-allocate / srun -- no job container.
  executor = "shell";

  # PATH for the shell-executor job shell: the stable ~/bin shims first (they
  # point at the tools' copy on the shared home, which the compute nodes can
  # read), then the nix profile, then the system.
  runnerPath = lib.concatStringsSep ":" [
    "${home}/bin"
    "${home}/.nix-profile/bin"
    "/usr/local/sbin" "/usr/local/bin"
    "/usr/sbin" "/usr/bin" "/sbin" "/bin"
  ];

  # Python envs are run with their site-packages named in PYTHONPATH: where
  # nix-portable falls back to proot, an env's symlinked bin/python resolves
  # to the bare interpreter and would not see the env's packages.
  pythonToml = pkgs.python3.withPackages (ps: [ ps.tomlkit ]);
  pyRun = env: "PYTHONPATH=${env}/${env.sitePackages} ${env}/bin/python3";
  pythonYaml = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);

  # slurm-job-local: one job of a project's .gitlab-ci.yml, run here the way
  # this runner would, from a working tree (slurm/slurm-job-local.py). It
  # reads YAML, hence the python with pyyaml.
  slurm-job-local = pkgs.runCommandLocal "slurm-job-local" { nativeBuildInputs = [ pkgs.makeWrapper ]; } ''
    mkdir -p $out/bin
    makeWrapper ${pythonYaml}/bin/python3 $out/bin/slurm-job-local \
      --prefix PYTHONPATH : ${pythonYaml}/${pythonYaml.sitePackages} \
      --add-flags ${../../slurm/slurm-job-local.py}
  '';

  # The pre_build_script is a single bash line that gitlab-runner's
  # shell-executor evals BEFORE every CI job's `script:` block, in the same
  # bash process. slurm-allocate reserves a SLURM allocation, exports
  # SLURM_PIPELINE_ALLOC and installs a `trap EXIT` that scancels it when the
  # job shell ends (success, fail, or cancel). The ~/bin shim keeps the line
  # the same across home-manager generations.
  preBuildScript = ''eval "$(${home}/bin/slurm-allocate)"'';

  # ── ~/.config/slurm-gitlab-ci/config ──────────────────────────────────
  # KEY="value" lines; lib/config.sh reads them, the environment wins.
  # Values are double-quoted shell words, so $USER and $HOME expand where the
  # tool runs (a compute node's $USER is the same, its paths may not be).
  shellWord = v: ''"${lib.replaceStrings [ "\\" "\"" "`" ] [ "\\\\" "\\\"" "\\`" ] v}"'';
  settings = lib.filterAttrs (_: v: v != null) ({
    GITLAB_URL = site.gitlabUrl;
    NODE_LOCAL_DIR = site.nodeLocalDir;
    SLURM_PARTITION = site.partition;
    SLURM_ACCOUNT = site.account;
    SLURM_QOS = site.qos;
    SLURM_GRES_NAME = site.gresName;
    SLURM_EXTRA_ARGS = if site.extraSallocArgs == [ ] then null else lib.concatStringsSep " " site.extraSallocArgs;
    SLURM_CI_NIX_PORTABLE = if site.nixPortable then "1" else "0";
    BUILDKIT_NODE = bk.node;
    BUILDKIT_IMAGE = bk.image;
    BUILDKIT_DAEMON_CPUS = toString bk.daemon.cpus;
    BUILDKIT_DAEMON_MEM = bk.daemon.mem;
    BUILDKIT_DAEMON_TIME = bk.daemon.time;
  } // site.extraSettings);
  configFile = pkgs.writeText "slurm-gitlab-ci-config" (''
    # Written by home-manager (services.slurmCi, .buildkitSlurm). Edits are
    # overwritten at the next switch. Read by every slurm-* tool
    # (slurm/lib/config.sh); a variable set in the environment wins.
  '' + lib.concatStrings (lib.mapAttrsToList (k: v: "${k}=${shellWord v}\n") settings));

  # buildkitd config. Registry mirrors: `FROM docker.io/*` pulls go through
  # them (host[:port], no scheme -- buildkitd defaults to https), e.g. a
  # pull-through cache against Docker Hub's rate limits.
  #
  # GC: one policy, and keepDuration is the point of it. `slurm-run` mounts
  # the build's snapshot directories as fuse-overlayfs lower layers straight
  # out of BuildKit's state -- BuildKit holds no lease for that use and cannot
  # see it. With a plain size limit its GC prunes the least-recently-used
  # snapshots whenever the state passes the limit -- including the layers of
  # a long job that is still running on them (its files vanish mid-run, after
  # a busy afternoon of other builds). So nothing used within keepDuration is
  # a candidate; set it above your longest SLURM_TIME. Above maxUsedSpace the
  # rest goes, least recently used first; the state may overshoot it for
  # keepDuration.
  buildkitdConfig = pkgs.writeText "buildkitd.toml" (
    lib.optionalString (bk.registryMirrors != [ ]) ''
      [registry."docker.io"]
        mirrors = [${lib.concatMapStringsSep ", " (m: ''"${m}"'') bk.registryMirrors}]

    '' + ''
      [worker.oci]
        gc = true
        [[worker.oci.gcpolicy]]
          all = true
          keepDuration = "${bk.gc.keepDuration}"
          maxUsedSpace = "${bk.gc.maxUsedSpace}"
    '');

  # The tools (slurm/), plus a statically-linked `fakemount` seccomp helper
  # and buildkitd.toml. Plain bash and python over system tools (srun,
  # singularity, curl, python3): they run on the compute nodes too.
  slurm-build-scripts = pkgs.pkgsMusl.stdenv.mkDerivation {
    pname = "slurm-build-scripts";
    version = "0.3.0";
    # Self-sourced relative to this module, so it can be consumed as a
    # homeManagerModule from another flake.
    src = ../../slurm;
    # Copy without the source's permissions: where nix-portable builds under
    # proot, the default unpack fails to write into the read-only copy
    # ("cp: cannot create regular file ...: Permission denied").
    unpackPhase = ''
      runHook preUnpack
      mkdir source
      cp -r --no-preserve=mode,ownership,timestamps $src/* source/
      chmod -R u+w source
      cd source
      runHook postUnpack
    '';
    # Keep the original #!/bin/bash shebangs: the scripts run on compute
    # nodes, where a /nix/store/...-bash path need not exist.
    dontPatchShebangs = true;
    buildPhase = ''
      runHook preBuild
      cc -static -O2 -o fakemount fakemount.c
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      mkdir -p $out/share/slurm-build $out/bin
      cp -r ./. $out/share/slurm-build/
      cp ${buildkitdConfig} $out/share/slurm-build/buildkitd.toml
      chmod -R +w $out/share/slurm-build
      chmod +x $out/share/slurm-build/bin/* $out/share/slurm-build/fakemount \
        $out/share/slurm-build/*.sh $out/share/slurm-build/*.py
      for s in $out/share/slurm-build/bin/*; do
        ln -s "$s" "$out/bin/$(basename "$s")"
      done
      runHook postInstall
    '';
    meta = {
      description = "GitLab CI on SLURM: allocation, BuildKit image builds and job tools";
      license = lib.licenses.gpl3Only;
      platforms = lib.platforms.linux;
    };
  };

  # Every tool with a ~/bin shim. The shims exec the tools' copy on the
  # shared home (below), which a compute node, cron and `ssh login-node cmd`
  # can all run -- unlike a /nix/store path, which under nix-portable exists
  # only inside its wrap, and with a system nix often only on the login node.
  shimmed = [
    "slurm-allocate" "slurm-build" "slurm-run" "slurm-sif" "slurm-cache"
    "slurm-monitor" "slurm-service" "package" "upload-to-package-registry"
  ];
  toolsBase = "${home}/.local/share/slurm-gitlab-ci";

  # `nix-portable` self-wrap for a command that needs /nix/store (the
  # nix-built gitlab-runner and crane). A no-op with a system nix.
  wrapIfPortable = cmd: if site.nixPortable then ''
    if [ ! -d /nix/store ] && [ -x "\$HOME/bin/nix-portable" ]; then
        export NIX_PORTABLE_SHELL=1
        exec "\$HOME/bin/nix-portable" debug /usr/bin/bash -c '${cmd} "\$@"' -- "\$@"
    fi
    exec ${cmd} "\$@"
  '' else ''
    exec ${cmd} "\$@"
  '';

  # Idempotent post-`register` patcher: sets top-level `concurrent` and, on
  # every shell-executor [[runners]] block, `environment`,
  # `request_concurrency`, `pre_build_script` and (if configured) the name.
  # Exits 0 if config.toml isn't there yet, so a switch works before the
  # first `gitlab-runner register`. tomlkit keeps comments, key order and
  # untouched fields as they are.
  runnerNames = lib.mapAttrs (_: r: r.name) (lib.filterAttrs (_: r: r.name != null) cfg.runners);
  envLine = [ "PATH=${runnerPath}" ]
    ++ lib.optional site.nixPortable "NIX_PORTABLE_SHELL=1"
    ++ cfg.extraEnvironment;
  patchGitlabRunnerConfig = pkgs.writeShellScript "patch-gitlab-runner-config" ''
    set -euo pipefail
    cfg="$HOME/.gitlab-runner/config.toml"
    if [ ! -f "$cfg" ]; then
      echo "gitlab-runner: $cfg not found — register a runner, then switch again" >&2
      exit 0
    fi
    GR_CFG="$cfg" \
    GR_CONCURRENT=${toString cfg.concurrency} \
    GR_REQUEST_CONCURRENCY=${toString cfg.requestConcurrency} \
    GR_ENV=${lib.escapeShellArg (builtins.toJSON envLine)} \
    GR_PRE_BUILD_SCRIPT=${lib.escapeShellArg preBuildScript} \
    GR_NAMES=${lib.escapeShellArg (builtins.toJSON runnerNames)} \
    GR_EXECUTOR=${lib.escapeShellArg executor} \
      ${pyRun pythonToml} - <<'PY'
    import json, os, pathlib, tomlkit
    cfg = pathlib.Path(os.environ["GR_CFG"])
    doc = tomlkit.parse(cfg.read_text())
    doc["concurrent"] = int(os.environ["GR_CONCURRENT"])
    # No RUNNER_CACHE here, on purpose: a constant in every job's environment
    # would name a path that exists only inside a container slurm-run
    # launched. run-buildkit-overlay.sh exports it next to the bind that
    # makes it real; everywhere else libraries fall back to ~/.cache.
    env_line = json.loads(os.environ["GR_ENV"])
    req_conc = int(os.environ["GR_REQUEST_CONCURRENCY"])
    pre_build = os.environ["GR_PRE_BUILD_SCRIPT"]
    names = json.loads(os.environ["GR_NAMES"])
    runners = doc.get("runners", [])
    patched = 0
    for r in runners:
        if r.get("executor") != os.environ["GR_EXECUTOR"]:
            # Another executor (docker, kubernetes, ...) in the same daemon is
            # left alone: slurm-allocate in its pre_build_script would break it.
            print(f"gitlab-runner: runner {r.get('id')} uses executor {r.get('executor')!r}, "
                  f"not {os.environ['GR_EXECUTOR']!r} -- left as it is")
            continue
        r["environment"] = env_line
        r["request_concurrency"] = req_conc
        r["pre_build_script"] = pre_build
        want = names.get(str(r.get("id")))
        if want:
            r["name"] = want
        patched += 1
    # force 2-space indent on the injected lines to match siblings.
    out = tomlkit.dumps(doc)
    out = out.replace("\nenvironment = [", "\n  environment = [")
    out = out.replace("\nrequest_concurrency = ", "\n  request_concurrency = ")
    out = out.replace("\npre_build_script = ", "\n  pre_build_script = ")
    cfg.write_text(out)
    print(f"gitlab-runner: patched {cfg} (concurrent={doc['concurrent']}, "
          f"shell runners={patched} of {len(runners)}, request_concurrency={req_conc})")
    PY
  '';

  # Puts each configured runner's name, extra tags and maintenance note into
  # GitLab. Needs a token that may edit the runners (GITLAB_TOKEN, a personal
  # access token with `api`) -- the runners' own glrt tokens cannot.
  # Idempotent; keeps every existing tag.
  runnerMeta = lib.mapAttrs (_: r: {
    inherit (r) name;
    tags = r.extraTags;
    note = r.maintenanceNote;
  }) cfg.runners;
  syncMetadata = pkgs.writeShellScriptBin "gitlab-runner-sync-metadata" ''
    set -euo pipefail
    : "''${GITLAB_TOKEN:?set GITLAB_TOKEN to a personal access token (scope api) that may edit these runners}"
    GR_META=${lib.escapeShellArg (builtins.toJSON runnerMeta)} \
    GR_URL=${lib.escapeShellArg (if site.gitlabUrl == null then "" else site.gitlabUrl)} \
      ${pkgs.python3}/bin/python3 - <<'PY'
    import json, os, sys, urllib.parse, urllib.request
    meta, url = json.loads(os.environ["GR_META"]), os.environ["GR_URL"].rstrip("/")
    if not url:
        sys.exit("set services.slurmCi.gitlabUrl first")
    if not meta:
        sys.exit("no runners in services.gitlabRunnerSlurm.runners")
    def call(method, path, data=None):
        req = urllib.request.Request(f"{url}/api/v4{path}", method=method,
                                     data=urllib.parse.urlencode(data, doseq=True).encode() if data else None,
                                     headers={"PRIVATE-TOKEN": os.environ["GITLAB_TOKEN"]})
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r)
    for rid, m in sorted(meta.items()):
        r = call("GET", f"/runners/{rid}")
        update = {}
        if m["name"]:
            update["description"] = m["name"]
        tags = sorted(set(r.get("tag_list") or []) | set(m["tags"]))
        if tags != sorted(r.get("tag_list") or []):
            update["tag_list"] = ",".join(tags)
        if m["note"] is not None:
            update["maintenance_note"] = m["note"]
        if update:
            call("PUT", f"/runners/{rid}", update)
        print(f"runner {rid}: {update or 'unchanged'}")
    PY
  '';

  runnerSubmodule = lib.types.submodule {
    options = {
      name = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "alice-ml_group_on_slurm-shellrunner";
        description = ''
          The runner's name: `name` in config.toml, and its description in
          GitLab (gitlab-runner-sync-metadata). null: left as registered.
        '';
      };
      extraTags = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = cfg.defaultExtraTags;
        defaultText = lib.literalExpression "config.services.gitlabRunnerSlurm.defaultExtraTags";
        description = "Tags gitlab-runner-sync-metadata adds in GitLab (existing tags are kept).";
      };
      maintenanceNote = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = cfg.defaultMaintenanceNote;
        defaultText = lib.literalExpression "config.services.gitlabRunnerSlurm.defaultMaintenanceNote";
        description = "The runner's maintenance note in GitLab; null leaves it alone.";
      };
    };
  };
  nullStr = lib.types.nullOr lib.types.str;
in {
  options.services.slurmCi = {
    gitlabUrl = lib.mkOption {
      type = nullStr;
      default = null;
      example = "https://gitlab.example.org";
      description = ''
        The GitLab the runners are registered with. Inside a job the tools
        use CI_SERVER_URL; this is for everything outside one (package,
        slurm-cache, slurm-job-local, gitlab-runner-sync-metadata).
      '';
    };
    nodeLocalDir = lib.mkOption {
      type = lib.types.str;
      default = "/tmp/$USER";
      example = "/scratch/local/$USER";
      description = ''
        A per-user directory on each compute node's LOCAL disk, the same path
        on every node ($USER expands there). The BuildKit rootfs and state,
        the runner cache and singularity's layer cache live under it. It must
        not be NFS (overlayfs does not stack on it); one that survives reboots
        keeps the build cache warm. Ask your admins which disk that is.
      '';
    };
    partition = lib.mkOption { type = nullStr; default = null; example = "gpu"; description = "SLURM partition for every allocation (null: the cluster default)."; };
    account = lib.mkOption { type = nullStr; default = null; description = "SLURM account for every allocation."; };
    qos = lib.mkOption { type = nullStr; default = null; description = "SLURM QOS for every allocation."; };
    gresName = lib.mkOption {
      type = lib.types.str;
      default = "gpu";
      description = "The GRES that counts GPUs (`--gres=<name>:N`).";
    };
    extraSallocArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "--constraint=a100" ];
      description = "More salloc arguments for every CI job (no spaces inside one argument).";
    };
    nixPortable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Nix runs through nix-portable (~/bin/nix-portable, no root, the
        store only inside its wrap): the runner and the nix-built helpers
        enter the wrap first. false for a system-wide nix install.
      '';
    };
    extraSettings = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = { SIF_PARTITION = "cpu"; SIF_PROTECT_DIR = "$HOME/services"; };
      description = "More KEY = value lines for ~/.config/slurm-gitlab-ci/config (see slurm/lib/config.sh and the tools' headers).";
    };
  };

  options.services.buildkitSlurm = {
    enable = lib.mkEnableOption ''
      the persistent BuildKit daemon on services.buildkitSlurm.node (a 24 h
      sbatch, kept alive by ~/bin/buildkitd-keepalive) and seeding its
      rootfs. slurm-build and the runner's image builds need it'';
    node = lib.mkOption {
      type = nullStr;
      default = null;
      example = "gpu-node-01";
      description = ''
        The compute node that hosts the BuildKit daemon. It needs
        unprivileged user namespaces and a subuid/subgid range for you
        (docs/admin-requirements.md). Jobs that build or run images are
        placed on it.
      '';
    };
    image = lib.mkOption {
      type = lib.types.str;
      default = "docker.io/moby/buildkit:v0.18.2";
      description = "The BuildKit image the rootfs is seeded from.";
    };
    registryMirrors = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "mirror.example.org:5000" ];
      description = "host[:port] of Docker Hub mirrors (pull-through caches) for `FROM docker.io/...`.";
    };
    gc = {
      keepDuration = lib.mkOption {
        type = lib.types.str;
        default = "12h";
        description = "Never prune a snapshot used within this long; above your longest SLURM_TIME.";
      };
      maxUsedSpace = lib.mkOption {
        type = lib.types.str;
        default = "300GB";
        description = "Prune the least recently used snapshots above this much state.";
      };
    };
    daemon = {
      cpus = lib.mkOption { type = lib.types.ints.positive; default = 2; description = "CPUs of the daemon's sbatch."; };
      mem = lib.mkOption { type = lib.types.str; default = "4G"; description = "Memory of the daemon's sbatch."; };
      time = lib.mkOption { type = lib.types.str; default = "24:00:00"; description = "Time limit of the daemon's sbatch (its renewal cycle)."; };
    };
  };

  options.services.gitlabRunnerSlurm = {
    enable = lib.mkEnableOption ''
      the gitlab-runner daemon: its systemd --user unit, enabled and
      (re)started on every switch that changes it, and linger, so it comes
      back after a reboot. Register runners first (docs/setup.md)'';
    concurrency = lib.mkOption {
      type = lib.types.ints.positive;
      default = 10;
      description = "`concurrent` in config.toml: jobs this daemon runs at once, over all runners.";
    };
    requestConcurrency = lib.mkOption {
      type = lib.types.ints.positive;
      default = 4;
      description = ''
        Per-runner long-poll parallelism. At 1 gitlab-runner warns of a
        request bottleneck, which shows up as minutes of idle between jobs
        when several runners share this daemon.
      '';
    };
    extraEnvironment = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "HF_HOME=$HOME/.cache/huggingface" ];
      description = "More KEY=VALUE entries for every shell runner's `environment`.";
    };
    runners = lib.mkOption {
      type = lib.types.attrsOf runnerSubmodule;
      default = { };
      example = lib.literalExpression ''
        { "624" = { name = "alice-ml_group_on_slurm-shellrunner"; extraTags = [ "team-ml" ]; }; }
      '';
      description = ''
        Per registered runner (its id, as in GitLab and in config.toml): the
        name, tags and maintenance note to give it. Optional -- for sites
        with a naming policy for runners. The patcher sets the local name;
        gitlab-runner-sync-metadata puts all of it into GitLab.
      '';
    };
    defaultExtraTags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "The default of runners.<id>.extraTags.";
    };
    defaultMaintenanceNote = lib.mkOption {
      type = nullStr;
      default = null;
      example = "Owner: Alice Example";
      description = "The default of runners.<id>.maintenanceNote.";
    };
  };

  config = {
    assertions = [
      {
        assertion = !bk.enable || bk.node != null;
        message = "services.buildkitSlurm.enable needs services.buildkitSlurm.node: the compute node that hosts the daemon.";
      }
      {
        assertion = !cfg.enable || site.gitlabUrl != null;
        message = "services.gitlabRunnerSlurm.enable needs services.slurmCi.gitlabUrl.";
      }
    ];

    # home-manager itself is not installed here: under nix-portable it is
    # installed with `nix profile install` (bootstrap/install.sh), because
    # nix-portable's bwrap cannot nest the mount namespace
    # `nix run nixpkgs#home-manager` needs.
    home.packages = with pkgs; [
      syncMetadata
      slurm-job-local
      gitlab-runner
      go-containerregistry   # crane, for bootstrap-buildkit-rootfs
      skopeo
      jq
      glab
      curl
      slurm-build-scripts
    ];

    home.activation.slurmCiConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      # A real file, not a link into the store: compute nodes and cron read it.
      mkdir -p "$HOME/.config/slurm-gitlab-ci"
      install -m 0644 ${configFile} "$HOME/.config/slurm-gitlab-ci/config"
      if [ ! -e "$HOME/.config/slurm-gitlab-ci/secrets" ]; then
        ( umask 077; printf '%s\n' \
          '# GITLAB_TOKEN=glpat-...   # personal access token, for package / slurm-cache outside CI' \
          > "$HOME/.config/slurm-gitlab-ci/secrets" )
      fi
    '';

    home.activation.gitlabRunnerPatch = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      ${patchGitlabRunnerConfig}
    '';

    # The tools as real files on the shared home, one directory per version,
    # `tools` pointing at the current one. A running job keeps the version it
    # started with (its scripts resolve to the versioned path); versions
    # other than the current one go a week after they were replaced.
    home.activation.slurmCiTools = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      base=${lib.escapeShellArg toolsBase}
      ver="$(basename ${slurm-build-scripts})"
      mkdir -p "$base"
      if [ ! -x "$base/$ver/bin/slurm-allocate" ]; then
        rm -rf "$base/$ver.tmp"
        cp -r ${slurm-build-scripts}/share/slurm-build "$base/$ver.tmp"
        chmod -R u+w "$base/$ver.tmp"
        mv "$base/$ver.tmp" "$base/$ver"
      fi
      if [ "$(readlink "$base/tools" 2>/dev/null)" != "$ver" ]; then
        [ -L "$base/tools" ] && touch -h "$base/$(readlink "$base/tools")" 2>/dev/null || true
        ln -sfn "$ver" "$base/tools.new" && mv -T "$base/tools.new" "$base/tools"
      fi
      find "$base" -mindepth 1 -maxdepth 1 -type d -name '*-slurm-build-scripts-*' \
        ! -name "$ver" -mtime +7 -exec rm -rf {} + 2>/dev/null || true

      mkdir -p "$HOME/bin"
      for t in ${lib.concatStringsSep " " shimmed}; do
        cat > "$HOME/bin/$t" <<SHIM
      #!/bin/bash
      # Auto-generated by home-manager (slurm-runner module); do not edit.
      exec "$base/tools/bin/$t" "\$@"
      SHIM
        chmod +x "$HOME/bin/$t"
      done
    '';

    # The Debian default ~/.bash_logout runs `clear_console -q`, which exits 1
    # when stdout is not a TTY. gitlab-runner's shell executor starts `bash
    # --login` without a terminal, so that non-zero propagates and every job
    # fails at prepare_environment with "exit status 1". Gate it on a TTY.
    home.activation.safeBashLogout = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      if [ -f "$HOME/.bash_logout" ] && grep -q clear_console "$HOME/.bash_logout" \
         && ! grep -q 'slurm-runner module' "$HOME/.bash_logout"; then
        cp -p "$HOME/.bash_logout" "$HOME/.bash_logout.pre-slurm-runner"
        cat > "$HOME/.bash_logout" <<'LOGOUT'
      # Written by home-manager (slurm-runner module): the distribution default,
      # gated on a TTY so non-interactive login shells (CI jobs) exit 0.
      # The previous version is ~/.bash_logout.pre-slurm-runner.
      if [ "$SHLVL" = 1 ] && [ -t 1 ]; then
          [ -x /usr/bin/clear_console ] && /usr/bin/clear_console -q
      fi
      true
      LOGOUT
      fi
    '';

    # ~/bin/bootstrap-buildkit-rootfs: crane is nix-built, so it enters
    # nix-portable first where that is how nix runs. Idempotent (it exits at
    # once if the rootfs is there), so with buildkitSlurm enabled every switch
    # fires it. After installPackages: crane is on PATH (~/.nix-profile/bin)
    # only once the new generation is in the profile.
    home.activation.bootstrapBuildkitRootfsShim = lib.hm.dag.entryAfter [ "installPackages" "slurmCiTools" ] (''
      mkdir -p "$HOME/bin" "$HOME/.local/share/buildkitd-sbatch"
      cat > "$HOME/bin/bootstrap-buildkit-rootfs" <<SHIM
      #!/bin/bash
      # Auto-generated by home-manager (slurm-runner module); do not edit.
      ${wrapIfPortable "${toolsBase}/tools/bin/bootstrap-buildkit-rootfs"}
      SHIM
      chmod +x "$HOME/bin/bootstrap-buildkit-rootfs"
    '' + lib.optionalString bk.enable ''
      # || true: a busy cluster or a network hiccup must not fail the switch.
      "$HOME/bin/bootstrap-buildkit-rootfs" \
        >>"$HOME/.local/share/buildkitd-sbatch/bootstrap.log" 2>&1 || true
    '');

    # Persistent BuildKit daemon. ensure-buildkitd-sbatch is idempotent: if a
    # buildkitd-<node> sbatch is queued or running it does nothing, otherwise
    # it submits a 24 h sbatch that runs buildkitd in the foreground.
    #
    # It is kept alive from the user's crontab: the daemon is a SLURM job,
    # not a unit, so linger can't bring it back. The crontab line is the one
    # manual step (docs/setup.md): /usr/bin/crontab is setuid and fails
    # inside nix-portable's wrap, where activation runs.
    home.activation.buildkitdKeepaliveShim = lib.hm.dag.entryAfter [ "bootstrapBuildkitRootfsShim" ] (''
      mkdir -p "$HOME/bin" "$HOME/.local/share/buildkitd-sbatch"
      cat > "$HOME/bin/buildkitd-keepalive" <<SHIM
      #!/bin/bash
      # Auto-generated by home-manager (slurm-runner module); do not edit.
      exec "${toolsBase}/tools/bin/ensure-buildkitd-sbatch" "\$@"
      SHIM
      chmod +x "$HOME/bin/buildkitd-keepalive"
    '' + lib.optionalString bk.enable ''
      # Once now, so the daemon comes up without waiting on the cron.
      "$HOME/bin/buildkitd-keepalive" \
        >>"$HOME/.local/share/buildkitd-sbatch/cron.log" 2>&1 || true
    '');

    # ── gitlab-runner daemon ───────────────────────────────────────────────
    #
    # A nohup-started runner dies with its login session (logind SIGTERMs
    # session processes on logout), and silently after a reboot. So it is a
    # systemd --user service:
    #
    #   * ExecStart is a stable-path shim (~/bin/gitlab-runner-run) that
    #     enters nix-portable if needed (the nix-built binary's ELF
    #     interpreter lives in /nix/store, which systemd may not see).
    #   * The unit is a REAL file (systemd --user can't read a unit that is a
    #     symlink into a store it cannot see), so not systemd.user.services.
    #
    # With linger the user manager starts at boot and default.target pulls
    # this unit up -- no login session needed. gitlab-runner-keepalive (cron)
    # is the backstop, and the fallback where there is no systemd --user.
    home.activation.gitlabRunnerRunShim = lib.hm.dag.entryAfter [ "installPackages" ] ''
      mkdir -p "$HOME/bin" "$HOME/logs/gitlab-runner"
      cat > "$HOME/bin/gitlab-runner-run" <<SHIM
      #!/bin/bash
      # Auto-generated by home-manager (slurm-runner module); do not edit.
      # Runs this home-manager generation's gitlab-runner in daemon mode.
      set -- run "\$@"
      ${wrapIfPortable "${pkgs.gitlab-runner}/bin/gitlab-runner"}
      SHIM
      chmod +x "$HOME/bin/gitlab-runner-run"

      cat > "$HOME/bin/gitlab-runner-keepalive" <<'SHIM'
      #!/bin/bash
      # Auto-generated by home-manager (slurm-runner module); do not edit.
      # Reboot backstop (cron, docs/setup.md): the systemd user unit is running.
      # Started through systemctl, the process stays out of the cron session,
      # so logind can't kill it. Without a reachable systemd --user, the
      # runner is started detached instead and tracked by a pid file.
      export XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
      if systemctl --user show-environment >/dev/null 2>&1; then
          systemctl --user is-active --quiet gitlab-runner || {
              echo "$(date -Is) gitlab-runner not active — starting"
              systemctl --user start gitlab-runner
          }
      else
          pidf="$HOME/logs/gitlab-runner/runner.pid"
          if [ -s "$pidf" ] && kill -0 "$(cat "$pidf")" 2>/dev/null; then exit 0; fi
          echo "$(date -Is) no systemd --user; starting gitlab-runner detached"
          setsid nohup "$HOME/bin/gitlab-runner-run" >>"$HOME/logs/gitlab-runner/runner.log" 2>&1 < /dev/null &
          echo $! > "$pidf"
      fi
      SHIM
      chmod +x "$HOME/bin/gitlab-runner-keepalive"
    '';

    home.activation.gitlabRunnerUnit = lib.mkIf cfg.enable (
      lib.hm.dag.entryAfter [ "linkGeneration" "gitlabRunnerRunShim" ] ''
        # systemctl lives in /usr/bin, which may not be on the activation
        # PATH; it talks to the real user systemd via XDG_RUNTIME_DIR.
        export PATH="/usr/bin:/bin:$PATH"
        if ! systemctl --user show-environment >/dev/null 2>&1; then
          echo "gitlab-runner: no systemd --user here; the keepalive cron line starts it (docs/setup.md)"
        else
        mkdir -p "$HOME/.config/systemd/user"
        cat > "$HOME/.config/systemd/user/gitlab-runner.service" <<UNIT
        [Unit]
        Description=gitlab-runner — SLURM shell-executor runner (nix-managed)
        After=network-online.target
        Wants=network-online.target

        [Service]
        Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
        ExecStart=$HOME/bin/gitlab-runner-run
        Restart=on-failure
        RestartSec=5s

        [Install]
        WantedBy=default.target
        UNIT
        systemctl --user daemon-reload || true
        systemctl --user enable gitlab-runner.service 2>/dev/null || true
        # RESTART ONLY WHAT CHANGED: the unit and the launcher shim (which
        # names the package's store path) are hashed, and the service is
        # restarted when that differs from the last start or when it is not
        # running. A restart on every switch would interrupt running jobs.
        _stamp="$(cat "$HOME/.config/systemd/user/gitlab-runner.service" "$HOME/bin/gitlab-runner-run" | sha256sum | cut -d" " -f1)"
        _stampfile="$HOME/.local/state/gitlab-runner.deployed"
        mkdir -p "$HOME/.local/state"
        if [ "$(cat "$_stampfile" 2>/dev/null)" != "$_stamp" ] || ! systemctl --user is-active -q gitlab-runner.service; then
          systemctl --user restart gitlab-runner.service || true
          echo "$_stamp" > "$_stampfile"
        else
          echo "gitlab-runner: unit and package unchanged -- not restarted"
        fi
        # Linger: systemd starts the user manager (and so this unit) at boot,
        # with no login session. Usually allowed to users by polkit; where it
        # is not, ask an admin (`loginctl enable-linger <user>`) or rely on
        # the keepalive cron line.
        loginctl enable-linger 2>/dev/null || echo "gitlab-runner: could not enable linger (docs/admin-requirements.md)"
        fi
      '');
  };
}
