# slurm-cache and package as an image, for where the cluster's PATH is not:
# a Kubernetes init container that fetches a published artifact (e.g. an
# index) onto a volume before the service starts.
#
#   slurm-cache fetch <name> <version> --project <id>    with SLURM_CACHE_DIR on the volume
#
# Built from this repository's own scripts (slurm/), so it is
# the same tool, the same format and the same verification as on the cluster.
FROM docker.io/library/alpine:3.20
RUN apk add --no-cache bash curl python3 coreutils findutils tar gzip
COPY slurm/bin/slurm-cache slurm/bin/package /opt/cluster-tools/bin/
COPY slurm/lib/registry.sh slurm/lib/dispatch.sh slurm/lib/config.sh /opt/cluster-tools/lib/
ENV PATH=/opt/cluster-tools/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    HOME=/tmp
CMD ["slurm-cache"]
