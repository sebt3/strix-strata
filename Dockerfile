ARG UBUNTU_TAG=24.04

# ─── Stage 1: Builder ────────────────────────────────────────────────────────
# Compiles the Strata HIP engine for gfx1151 (Strix Halo) with the ROCm wheels
# that Strata's own setup.py pins for that family (7.14.0a20260608, see
# upstream issue #1267 — later 7.14 nightlies segfault in hsa_init).
# No GPU is needed at build time.
FROM docker.io/library/ubuntu:${UBUNTU_TAG} AS builder
ARG STRATA_REPO=https://github.com/Niko1221/Strata.git
ARG STRATA_REF=v0.1.45
ARG GPU_ARCH=gfx1151
ARG BUILD_VISION=1

RUN DEBIAN_FRONTEND=noninteractive apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    build-essential ca-certificates curl git libatomic1 libgomp1 \
    python3 python3-pip python3-venv unzip \
 && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch ${STRATA_REF} ${STRATA_REPO} /opt/strata
WORKDIR /opt/strata

RUN python3 -m venv .venv \
 && .venv/bin/pip install --no-cache-dir -r requirements.txt

COPY build-engine.py /tmp/build-engine.py
RUN GPU_ARCH=${GPU_ARCH} BUILD_VISION=${BUILD_VISION} .venv/bin/python /tmp/build-engine.py \
 && rm -rf build-hip build-vision

# Prune the ROCm devel wheel: its compilers, benchmarks, docs and headers (~7 GB) are only needed
# to build the engine above. The runtime stage has no host compiler, so nothing can be rebuilt
# there anyway. lib/ stays whole: the engine loads libLLVM/libclang-cpp/comgr from it and
# hipBLASLt/rocBLAS read their kernel catalogs from it lazily (not visible in /proc/maps).
RUN D=.venv/lib/python3.12/site-packages/_rocm_sdk_devel \
 && du -sh /opt/strata \
 && rm -rf $D/bin $D/clients $D/share $D/include $D/tests $D/libexec \
 && du -sh /opt/strata && test -x engine/strata

# ─── Stage 2: Runtime ────────────────────────────────────────────────────────
FROM docker.io/library/ubuntu:${UBUNTU_TAG} AS runtime

RUN DEBIAN_FRONTEND=noninteractive apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates curl libatomic1 libgomp1 libnuma1 libdrm2 libelf1 \
    python3 python3-venv \
 && apt-get clean && rm -rf /var/lib/apt/lists/*

# venv (ROCm wheels included) + engine + sources: same path as in the builder,
# the venv has absolute shebangs.
COPY --from=builder /opt/strata /opt/strata
WORKDIR /opt/strata

# Models, prepared packs and the generated install config live on the volume
ENV STRATA_DATA=/data \
    STRATA_EXECV=1 \
    PYTHONUNBUFFERED=1 \
    FAMILY=coder \
    CONTEXT=65536 \
    HOST=0.0.0.0 \
    PORT=8080
VOLUME ["/data"]
EXPOSE 8080

# /health only answers once the model is loaded (1–3 min after the weights are on disk)
HEALTHCHECK --interval=30s --timeout=5s --start-period=600s --retries=3 \
    CMD curl -fsS http://127.0.0.1:${PORT}/health || exit 1

# Upstream entrypoint: first start runs `setup.py --setup --yes` (downloads the
# model into /data), later starts reuse /data/config.
ENTRYPOINT ["./docker-entrypoint.sh"]
