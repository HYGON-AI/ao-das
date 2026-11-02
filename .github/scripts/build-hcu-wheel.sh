#!/usr/bin/env bash
set -euo pipefail

pip_install() {
  : "${PYPI_URL:?PYPI_URL repository variable is required}"
  local index_url="${PYPI_URL%/}/nightly/dtk2604/+simple/"
  local host="${PYPI_URL#*://}"
  host="${host%%/*}"
  host="${host%%:*}"
  python -m pip install --index-url "${index_url}" \
    --trusted-host "${host}" "$@"
}

prepare_hcu() {
  local work_dir hipblaslt_dir hipblaslt_lib
  work_dir="$(mktemp -d)"
  curl -fL -C - -o "${work_dir}/hipblastLlib.tar.gz" \
    "https://ksefile.hpccube.com:65241/efile/s/d/c2NubXFneDI4ZQ==-/06d7d4df13daa892"
  tar -xzf "${work_dir}/hipblastLlib.tar.gz" -C "${work_dir}"
  hipblaslt_dir="$(find "${work_dir}" -type d -name hipblaslt -print -quit)"
  hipblaslt_lib="$(find "${work_dir}" -name libhipblaslt.so.0.10 -print -quit)"
  rm -rf /opt/dtk/lib/hipblaslt
  rm -f /opt/dtk/lib/libhipblaslt.so.0.10
  cp -a "${hipblaslt_dir}" /opt/dtk/lib/hipblaslt
  cp -a "${hipblaslt_lib}" /opt/dtk/lib/libhipblaslt.so.0.10
}

build_hcu_wheel() {
  pip_install "torch==${TORCH_VERSION}" setuptools wheel
  prepare_hcu
  source /opt/dtk/env.sh
  : "${LOCAL_RUN_ROOT:?LOCAL_RUN_ROOT is required}"
  mkdir -p "${LOCAL_RUN_ROOT}/dist"
  python setup.py bdist_wheel --dist-dir "${LOCAL_RUN_ROOT}/dist"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  build_hcu_wheel
fi
