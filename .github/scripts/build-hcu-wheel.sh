#!/usr/bin/env bash
set -euo pipefail

dtk_version_value="${DTK_VERSION:-}"
if [[ -z "${dtk_version_value}" ]]; then
  dtk_version_value="$(tr -d '.[:space:]' < /opt/dtk/.info/rocm_version)"
fi
case "${dtk_version_value}" in
  *2604*) DTK_VERSION=2604 ;;
  *2610*) DTK_VERSION=2610 ;;
  *2704*) DTK_VERSION=2704 ;;
  *) echo "Unsupported DTK version: ${dtk_version_value}" >&2; exit 1 ;;
esac
if [[ -z "${PIP_INDEX_PATH:-}" ]]; then
  case "${DTK_VERSION}" in
    2604) PIP_INDEX_PATH=das_nightly/dtk2604-rc4 ;;
    2610) PIP_INDEX_PATH=das_nightly/dtk2610 ;;
    2704) PIP_INDEX_PATH=nightly/dtk2704 ;;
    *) echo "Unsupported DTK version: ${DTK_VERSION}" >&2; exit 1 ;;
  esac
fi
export DTK_VERSION PIP_INDEX_PATH

pip_install() {
  : "${PYPI_URL:?PYPI_URL repository variable is required}"
  local package_index="${PIP_INDEX_PATH:-nightly/dtk2604}"
  # das_nightly only hosts DTK-specific wheels; common Python build/test
  # dependencies remain in the nightly index for the matching base release.
  if [[ "${package_index}" == das_nightly/* ]]; then
    package_index=nightly/dtk2604
  fi
  local index_url="${PYPI_URL%/}/${package_index}/+simple/"
  local host="${PYPI_URL#*://}"
  host="${host%%/*}"
  host="${host%%:*}"
  python -m pip install --index-url "${index_url}" \
    --trusted-host "${host}" "$@"
}

resolve_torch_package() {
  python - <<'PY'
from html.parser import HTMLParser
from urllib.parse import urljoin
from urllib.request import urlopen
from pip._vendor.packaging.tags import sys_tags
from pip._vendor.packaging.utils import parse_wheel_filename
import os

class Links(HTMLParser):
    def __init__(self):
        super().__init__()
        self.hrefs = []
    def handle_starttag(self, tag, attrs):
        if tag == "a":
            self.hrefs.extend(value for key, value in attrs if key == "href")

index = os.environ["PYPI_URL"].rstrip("/") + "/" + os.environ["PIP_INDEX_PATH"] + "/+simple/torch/"
parser = Links()
parser.feed(urlopen(index, timeout=30).read().decode())
supported = set(sys_tags())
dtk_tag = "dtk" + os.environ["DTK_VERSION"] + "."
candidates = []
for href in parser.hrefs:
    url = urljoin(index, href)
    filename = url.split("/")[-1].split("#")[0]
    if not filename.endswith(".whl"):
        continue
    name, version, _, tags = parse_wheel_filename(filename)
    if name == "torch" and str(version).startswith(os.environ["TORCH_VERSION"] + "+" + dtk_tag) and tags & supported:
        candidates.append((version, url))
if not candidates:
    raise SystemExit(f"No compatible torch wheel for {dtk_tag} in {index}")
print(max(candidates)[1])
PY
}

prepare_hcu() {
  local work_dir hipblaslt_dir hipblaslt_lib
  work_dir="$(mktemp -d)"
  curl -fL -C - -o "${work_dir}/hipblastLlib.tar.gz" \
    "https://ksefile.hpccube.com:65241/efile/s/d/c2NubXFneDI4ZQ==/06d7d4df13daa892"
  tar -xzf "${work_dir}/hipblastLlib.tar.gz" -C "${work_dir}"
  hipblaslt_dir="$(find "${work_dir}" -type d -name hipblaslt -print -quit)"
  hipblaslt_lib="$(find "${work_dir}" -name libhipblaslt.so.0.10 -print -quit)"
  rm -rf /opt/dtk/lib/hipblaslt
  rm -f /opt/dtk/lib/libhipblaslt.so.0.10
  cp -a "${hipblaslt_dir}" /opt/dtk/lib/hipblaslt
  cp -a "${hipblaslt_lib}" /opt/dtk/lib/libhipblaslt.so.0.10
}

build_hcu_wheel() {
  local torch_package
  torch_package="$(resolve_torch_package)"
  pip_install "${torch_package}" setuptools wheel
  if [[ "${DTK_VERSION}" == 2604 ]]; then
    prepare_hcu
  fi
  source /opt/dtk/env.sh
  : "${LOCAL_RUN_ROOT:?LOCAL_RUN_ROOT is required}"
  local raw_wheel_dir="${LOCAL_RUN_ROOT}/raw-dist"
  local wheel_dir="${LOCAL_RUN_ROOT}/dist"
  mkdir -p "${raw_wheel_dir}" "${wheel_dir}"
  python setup.py bdist_wheel --dist-dir "${raw_wheel_dir}"
  build_manylinux_wheel "${raw_wheel_dir}" "${wheel_dir}"
}

build_manylinux_wheel() {
  local raw_wheel_dir="$1"
  local wheel_dir="$2"
  local glibc_version platform
  local -a wheels excludes auditwheel_excludes

  pip_install auditwheel patchelf

  shopt -s nullglob
  wheels=("${raw_wheel_dir}"/*-linux_x86_64.whl)
  shopt -u nullglob
  (( ${#wheels[@]} == 1 )) || {
    echo "Expected one Linux wheel in ${raw_wheel_dir}, found ${#wheels[@]}" >&2
    exit 1
  }

  glibc_version="$(getconf GNU_LIBC_VERSION 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' || true)"
  [[ -n "${glibc_version}" ]] || {
    echo "Unable to determine the glibc version for the manylinux tag" >&2
    exit 1
  }
  platform="manylinux_${glibc_version/./_}_x86_64"

  # torchao._C is loaded into a DTK-enabled PyTorch process.  Do not bundle
  # DTK or PyTorch runtime libraries: they must match the installed torch/DTK.
  excludes=(
    'libgalaxyhip.so*' 'libMIOpen.so*' 'librccl.so*'
    'libhipblas.so*' 'libhipblaslt.so*' 'libhipfft.so*' 'libhiprand.so*'
    'libhiprtc.so*' 'libhipsolver.so*' 'libhipsparse.so*' 'libhipnn.so*'
    'librocblas.so*' 'librocsolver.so*' 'librocfft.so*' 'librocrand.so*'
    'librocsparse.so*' 'librocm_smi64.so*' 'librocfft-device-*.so*'
    'libhsa-runtime64.so*' 'libamdhip64.so*' 'libamd_comgr.so*' 'libhsakmt.so*'
    'libc10.so*' 'libc10_hip.so*' 'libtorch_cpu.so*' 'libtorch_hip.so*'
    'libtorch_python.so*' 'libtorch.so*'
  )
  for library in "${excludes[@]}"; do
    auditwheel_excludes+=(--exclude "${library}")
  done

  echo "========== Inspecting ${wheels[0]} for ${platform} =========="
  auditwheel show "${wheels[0]}"
  echo "========== Generating manylinux wheel (${platform}) =========="
  auditwheel repair --plat "${platform}" \
    "${auditwheel_excludes[@]}" \
    --wheel-dir "${wheel_dir}" \
    "${wheels[0]}"

  shopt -s nullglob
  wheels=("${wheel_dir}"/*manylinux*.whl)
  shopt -u nullglob
  (( ${#wheels[@]} == 1 )) || {
    echo "Expected one repaired manylinux wheel in ${wheel_dir}, found ${#wheels[@]}" >&2
    exit 1
  }
  echo "Generated manylinux wheel: ${wheels[0]}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  build_hcu_wheel
fi
