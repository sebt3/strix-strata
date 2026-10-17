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

Environment (read by upstream `docker-entrypoint.sh`): `FAMILY`, `MODEL`, `CONTEXT`,
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
