#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/build-hcu-wheel.sh"
pip_install "torch==${TORCH_VERSION}" openai==2.25.0 \
  aiter torchvision vllm vllm-hcu lightop triton aicc pytest
prepare_hcu
: "${LOCAL_RUN_ROOT:?LOCAL_RUN_ROOT is required}"
python -m pip install --no-deps --force-reinstall \
  "${LOCAL_RUN_ROOT}"/dist/*.whl

source /opt/dtk/env.sh
mv torchao/__init__.py torchao/__init__.py.bak
trap 'mv torchao/__init__.py.bak torchao/__init__.py' EXIT
python -m pytest test -vs \
  --deselect=test/quantization/pt2e/test_x86inductor_quantizer.py::TestQuantizePT2EX86Inductor::test_linear_reused_with_fusable_post_op
