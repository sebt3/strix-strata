"""Build the Strata HIP engine inside `docker build`, without a GPU.

Strata's own Dockerfile does the same for CUDA by importing setup.py and calling
its build functions; this is the HIP equivalent. Run from the Strata checkout
with its venv (cwd = /opt/strata).

setup.build_engine_hip(gpu, llama, vision) normally receives the dict produced by
GPU detection. There is no GPU at build time, so it is synthesized here.
Everything below the `gpu = {...}` line is what to adjust if upstream changes the
keys it reads.
"""
import os
import sys

sys.path.insert(0, os.getcwd())
import setup  # noqa: E402  (Strata's setup.py)

arch = os.environ.get("GPU_ARCH", "gfx1151")
vision = "cpu" if os.environ.get("BUILD_VISION", "0") == "1" else "none"

gpu = {"arch": arch, "name": f"AMD {arch}", "vendor": "amd"}

llama = setup.get_llama_cpp()  # downloads the pinned llama.cpp/ggml commit
eng = setup.build_engine_hip(gpu, llama, vision)
print(f"engine built in {eng}")
