#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/build-hcu-wheel.sh"

install_aicc() (
  : "${RESOURCE_SERVER_URL:?RESOURCE_SERVER_URL repository variable is required}"
  local installer
  installer="$(mktemp)"
  trap 'rm -f -- "${installer}"' EXIT
  wget --quiet --tries=3 --timeout=120 \
    --output-document="${installer}" -- \
    "${RESOURCE_SERVER_URL%/}/ai_cc/Nightly/hcu_llvm_installer.sh"
  bash "${installer}" --major 1.0.0 --dtk-dir /opt/dtk
  test -x /opt/dtk/bin/aicc
)

install_aicc
mapfile -t component_wheels < <(python - <<'PY'
from html.parser import HTMLParser
from urllib.parse import urljoin
from urllib.request import urlopen

from pip._vendor.packaging.tags import sys_tags
from pip._vendor.packaging.utils import parse_wheel_filename
import os
import sys


class Links(HTMLParser):
    def __init__(self):
        super().__init__()
        self.hrefs = []

    def handle_starttag(self, tag, attrs):
        if tag == "a":
            self.hrefs.extend(value for key, value in attrs if key == "href")


base = os.environ["PYPI_URL"].rstrip("/") + "/nightly/dtk2604/+simple/"
torch_tag = "torch" + os.environ["TORCH_VERSION"].replace(".", "")
supported = set(sys_tags())
for package in ("aiter", "torchvision", "lightop", "triton"):
    index = urljoin(base, package + "/")
    parser = Links()
    parser.feed(urlopen(index, timeout=30).read().decode())
    candidates = []
    for href in parser.hrefs:
        wheel_url = urljoin(index, href)
        filename = wheel_url.split("/")[-1].split("#")[0]
        if not filename.endswith(".whl"):
            continue
        name, version, _, tags = parse_wheel_filename(filename)
        if name == package and f"dtk2604.{torch_tag}." in str(version) and tags & supported:
            candidates.append((version, wheel_url))
    if not candidates:
        raise SystemExit(f"No compatible {package} wheel for {torch_tag} in {index}")
    version, wheel_url = max(candidates)
    print(wheel_url)
    print(f"Selected {package} {version}", file=sys.stderr)
PY
)
test "${#component_wheels[@]}" -eq 4
pip_install "torch==${TORCH_VERSION}" openai==2.25.0 \
  "${component_wheels[@]}" transformers==5.20.2 safetensors==0.8.0 \
  pytest expecttest parameterized fire tabulate
prepare_hcu
: "${LOCAL_RUN_ROOT:?LOCAL_RUN_ROOT is required}"
python -m pip install --no-deps --force-reinstall \
  "${LOCAL_RUN_ROOT}"/dist/*.whl

source /opt/dtk/env.sh
mv torchao/__init__.py torchao/__init__.py.bak
trap 'mv torchao/__init__.py.bak torchao/__init__.py' EXIT

run_with_failed_retry() {
  local cache_dir="$1"
  local first_limit="$2"
  local retry_limit="$3"
  local first_status=0
  shift 3
  if [[ "${first_limit}" == none ]]; then
    python -m pytest -vs -o "cache_dir=${cache_dir}" "$@" || first_status=$?
  else
    timeout --signal=TERM --kill-after=30s "${first_limit}" \
      python -m pytest -vs -o "cache_dir=${cache_dir}" "$@" || first_status=$?
  fi
  if (( first_status == 0 )); then
    return 0
  fi
  if (( first_status == 124 || first_status == 137 )); then
    echo "pytest exceeded ${first_limit}; skipping retry after forced termination" >&2
    return "${first_status}"
  fi
  if ! grep -q '"' "${cache_dir}/v/cache/lastfailed" 2>/dev/null; then
    echo "pytest stopped before recording failed tests; no targeted retry is possible" >&2
    return 1
  fi
  echo "Retrying only failed tests in ${cache_dir}" >&2
  if [[ "${retry_limit}" == none ]]; then
    python -m pytest -vs --last-failed --last-failed-no-failures=none \
      -o "cache_dir=${cache_dir}" "$@"
  else
    timeout --signal=TERM --kill-after=30s "${retry_limit}" \
      python -m pytest -vs --last-failed --last-failed-no-failures=none \
      -o "cache_dir=${cache_dir}" "$@"
  fi
}

run_with_failed_retry "${LOCAL_RUN_ROOT}/pytest-main" none none test \
  --deselect=test/quantization/pt2e/test_x86inductor_quantizer.py::TestQuantizePT2EX86Inductor::test_linear_reused_with_fusable_post_op
