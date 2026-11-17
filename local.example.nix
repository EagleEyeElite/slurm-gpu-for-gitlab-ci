# Your settings. Copy to ~/.config/slurm-gitlab-ci/local.nix (outside the
# checkout, so updates never conflict with it), edit, `hm-switch`.
#
# It is an ordinary home-manager module: anything else you want in your
# home on the login node can go here too.
#
# Nothing runs until you enable it: the two daemons are opt-in below.
{ ... }:
{
  services.slurmCi = {
    gitlabUrl = "https://gitlab.example.org";
    # A per-user directory on every compute node's LOCAL disk (not NFS).
    # Ask your admins which disk survives reboots; /tmp often does not.
    nodeLocalDir = "/tmp/$USER";
    # partition = "gpu";
    # account = "my-project";
    # qos = "normal";
    # gresName = "gpu";              # --gres=<gresName>:N
    # extraSallocArgs = [ "--constraint=a100" ];
    # nixPortable = false;           # with a system-wide nix install
    # extraSettings = { SIF_PARTITION = "cpu"; };
  };

  # The BuildKit daemon: needed for slurm-build / image jobs. The node needs
  # user namespaces and a subuid range for you (docs/admin-requirements.md).
  services.buildkitSlurm = {
    enable = false;
    node = "gpu-node-01";
    # registryMirrors = [ "mirror.example.org:5000" ];
    # gc.maxUsedSpace = "300GB";
  };

  # The gitlab-runner daemon. Register a runner first (docs/setup.md).
  services.gitlabRunnerSlurm = {
    enable = false;
    # concurrency = 10;
    # Optional: names, tags and notes in GitLab (gitlab-runner-sync-metadata).
    # runners."1234" = { name = "my-group_on_slurm"; extraTags = [ "gpu" ]; };
  };
}
