# Build from the existing runnable image after the release packages both roles.
# This layer adds no capabilities, cgroup delegation or relaxed sandbox flags.
ARG LOOM_RUNTIME_IMAGE=loom-runtime:dev
FROM ${LOOM_RUNTIME_IMAGE}
USER root
COPY --chmod=0755 docker/distributed/role-entrypoint.sh /opt/loom/bin/loom-distributed-role
USER loom
# Deliberately no org.loom.distributed.roles/protocol capability labels yet.
# Root release integration adds them only after actual role/container validation.
ENTRYPOINT ["tini", "--", "/opt/loom/bin/loom-distributed-role"]
CMD []
