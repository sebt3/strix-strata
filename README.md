# strix-strata

Container image for [Strata](https://github.com/Niko1221/Strata) (Qwen3.8-Flash-Next
inference engine) on AMD Strix Halo (Ryzen AI Max, **gfx1151**), ROCm/HIP backend.

Upstream only ships a CUDA Dockerfile and documents Strix Halo as *experimental*,
build-from-source. This repo builds the HIP engine at image build time so a container
only has to download the model.

Unofficial, not affiliated with the Strata author.

## Status

Alpha. Works on a Strix Halo (gfx1151): the Coder variant of Qwen3.8-Flash-Next serves ~42 tok/s
(decode) and ~650 tok/s (prefill). `build-engine.py` calls Strata internals
(`setup.get_llama_cpp`, `setup.build_engine_hip`) with a synthesized GPU dict, which upstream may break.

## Build

```bash
docker build -t strix-strata:dev .
# other release / other tag
docker build --build-arg STRATA_REF=v0.1.45 -t strix-strata:dev .
```

Build args: `STRATA_REF` (upstream tag, pin it), `GPU_ARCH` (default `gfx1151`),
`BUILD_VISION` (`1` builds the CPU image encoder, the default).

The ROCm devel wheel is pruned after the build (compilers, benchmarks, headers: ~7 GB): the
runtime has no host compiler, so nothing could be rebuilt there anyway. Its `lib/` is kept whole
(the engine loads LLVM/comgr from it and the BLAS libraries read kernel catalogs lazily). The CPU
image encoder is built into the image (`BUILD_VISION=1`), since it cannot be compiled at runtime.

## Run

```bash
docker run --rm -p 8080:8080 \
  --device /dev/kfd --device /dev/dri --group-add video --group-add render \
  --ulimit memlock=-1 --security-opt seccomp=unconfined \
  --stop-timeout 60 \
  -v strata-data:/data \
  -e FAMILY=coder -e CONTEXT=65536 -e API_KEY=changeme \
  strix-strata:dev
```

`--stop-timeout 60`: the engine releases its locked RAM on SIGTERM, which takes >10 s.

Environment added by this image (the entrypoint is `strix-entrypoint.sh`, which wraps upstream's):

- `PARALLEL` (2 to 8): conversations decoded together (Strata's batch slots, `docs/BATCHING.md`); `1` or
  unset: one request at a time. Upstream's entrypoint has no variable for it: it is written into the
  config's `"parallel"` at every start.
- `CONTEXT` is also applied to an existing config at every start (upstream only reads it at install or with
  `REINSTALL=1`).
- `STRATA_ARENA_MMAP=1` (read by the engine): the experts are mapped from a file (`experts.bin`, ~25 GB for the
  Coder) instead of being read into RAM next to the GPU's copy. On a unified-memory machine like the Strix
  Halo that copy is 23 GiB of RAM held twice. Measured on a Ryzen AI Max+ 395, Coder IQ1_M, 262144 tokens
  and 4 slots: 68 GiB used (90 without it, which stalls the machine), same prefill speed. The engine writes the
  file at the first start that has the variable and maps it from the next start on, but that first start still
  loads the experts in RAM; the wrapper therefore runs it small (`PARALLEL=1`, `CONTEXT=65536`), stops it once
  the file is written and starts again on the real settings, in the same container.

Environment read by upstream `docker-entrypoint.sh`: `FAMILY`, `MODEL`, `CONTEXT`,
`VISION`, `KV`, `GPU`, `GPUS`, `LOW_RAM`, `HOST`, `PORT`, `API_KEY`, `GGUF_DIR`,
`RESIDENT_BUDGET_GIB`, `KV_STREAMING`, `REINSTALL`, `CONFIG`.
Changing a setting for a model that is already installed needs `REINSTALL=1`.

API: OpenAI-compatible on `:8080/v1`, plus `/v1/messages` (Anthropic) and
`/v1/responses`. Health: `/health`.

## Host prerequisites (Strix Halo)

- `amdgpu` driver, `/dev/kfd`, user in `render` and `video`.
- To let the GPU use most of the RAM, upstream's reference machine boots with
  `ttm.pages_limit=29360128 ttm.page_pool_size=29360128 amd_iommu=off`.

## Known upstream pitfalls

- ROCm **7.10** wheels segfault on gfx1151 (fixed in Strata v0.1.40.2, which pins
  7.14.0a20260608). Nightlies 7.14.0a20260609–20260612 crash in `hsa_init`.
- The hipBLASLt tuning table for gfx1151 is not on by default; prompts run at about half
  speed without it (`STRATA_HIPBLASLT_TUNING`, normally set by setup in the generated config).
- `--expert-cache auto` can OOM a machine with a desktop session (upstream #1715).

## Versioning

`.tags` holds the image tag: `<strata version>-alpha.<n>`. Pushing to `main` builds and
pushes it to Docker Hub and GHCR (see `.github/workflows/docker-image.yml`).
