#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${DTK_VERSION:-}" ]]; then
  dtk_version_file="$(tr -d '.[:space:]' < /opt/dtk/.info/rocm_version)"
  case "${dtk_version_file}" in
    2604*) DTK_VERSION=2604 ;;
    2610*) DTK_VERSION=2610 ;;
    *) echo "Unsupported DTK version: ${dtk_version_file}" >&2; exit 1 ;;
  esac
fi
if [[ -z "${PIP_INDEX_PATH:-}" ]]; then
  case "${DTK_VERSION}" in
    2604) PIP_INDEX_PATH=das_nightly/dtk2604-rc4 ;;
    2610) PIP_INDEX_PATH=das_nightly/dtk2610 ;;
    *) echo "Unsupported DTK version: ${DTK_VERSION}" >&2; exit 1 ;;
  esac
fi
export DTK_VERSION PIP_INDEX_PATH

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
  local torch_package="torch==${TORCH_VERSION}"
  if [[ "${PIP_INDEX_PATH}" == das_nightly/* ]]; then
    torch_package="$(python - <<'PY'
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
candidates = []
for href in parser.hrefs:
    url = urljoin(index, href)
    filename = url.split("/")[-1].split("#")[0]
    if not filename.endswith(".whl"):
        continue
    name, version, _, tags = parse_wheel_filename(filename)
    dtk_tag = "dtk" + os.environ["DTK_VERSION"] + "."
    if name == "torch" and str(version).startswith(os.environ["TORCH_VERSION"] + "+" + dtk_tag) and tags & supported:
        candidates.append((version, url))
if not candidates:
    raise SystemExit(f"No compatible torch wheel for {dtk_tag} in {index}")
print(max(candidates)[1])
PY
)"
  fi
  pip_install "${torch_package}" setuptools wheel
  if [[ "${DTK_VERSION}" == 2604 ]]; then
    prepare_hcu
  fi
  source /opt/dtk/env.sh
  : "${LOCAL_RUN_ROOT:?LOCAL_RUN_ROOT is required}"
  mkdir -p "${LOCAL_RUN_ROOT}/dist"
  python setup.py bdist_wheel --dist-dir "${LOCAL_RUN_ROOT}/dist"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  build_hcu_wheel
fi
