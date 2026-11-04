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
for package in ("aiter", "torchvision", "vllm", "vllm-hcu", "lightop", "triton"):
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
test "${#component_wheels[@]}" -eq 6
pip_install "torch==${TORCH_VERSION}" openai==2.25.0 \
  "${component_wheels[@]}" pytest expecttest parameterized fire tabulate
prepare_hcu
: "${LOCAL_RUN_ROOT:?LOCAL_RUN_ROOT is required}"
python -m pip install --no-deps --force-reinstall \
  "${LOCAL_RUN_ROOT}"/dist/*.whl

source /opt/dtk/env.sh
mv torchao/__init__.py torchao/__init__.py.bak
trap 'mv torchao/__init__.py.bak torchao/__init__.py' EXIT

cat > "${LOCAL_RUN_ROOT}/hcu_vllm_first.py" <<'PY'
def pytest_collection_modifyitems(items):
    items.sort(
        key=lambda item: not item.nodeid.startswith("test/integration/test_vllm.py::")
    )
PY
export PYTHONPATH="${LOCAL_RUN_ROOT}${PYTHONPATH:+:${PYTHONPATH}}"

run_with_failed_retry() {
  local cache_dir="$1"
  shift
  if timeout --signal=TERM --kill-after=30s 150m \
    python -m pytest -p hcu_vllm_first -vs \
    -o "cache_dir=${cache_dir}" "$@"; then
    return 0
  fi
  if ! grep -q '"' "${cache_dir}/v/cache/lastfailed" 2>/dev/null; then
    echo "pytest stopped before recording failed tests; no targeted retry is possible" >&2
    return 1
  fi
  echo "Retrying only failed tests in ${cache_dir}" >&2
  timeout --signal=TERM --kill-after=30s 45m \
    python -m pytest -p hcu_vllm_first -vs \
    --last-failed --last-failed-no-failures=none \
    -o "cache_dir=${cache_dir}" "$@"
}

idle_devices="$(python - <<'PY'
import os
import sys
import torch

available = []
for device in range(torch.cuda.device_count()):
    free, total = torch.cuda.mem_get_info(device)
    ratio = free / total
    print(f"HCU {device}: {free / 2**30:.1f}/{total / 2**30:.1f} GiB free ({ratio:.1%})", file=sys.stderr)
    if ratio >= 0.95:
        available.append((device, free))
if len(available) < 2:
    raise SystemExit("vLLM tests require two HCU devices with at least 95% free memory")
offset = (int(os.environ.get("GITHUB_RUN_ID", "0")) + int(os.environ.get("GITHUB_RUN_ATTEMPT", "1")) - 1) % len(available)
available = available[offset:] + available[:offset]
available.sort(key=lambda item: item[1], reverse=True)
print(",".join(str(device) for device, _ in available[:2]))
PY
)"
export ROCR_VISIBLE_DEVICES="${idle_devices}"
export VLLM_WORKER_MULTIPROC_METHOD=spawn
echo "Running tests on HCU devices ${idle_devices}"
run_with_failed_retry "${LOCAL_RUN_ROOT}/pytest" test \
  --deselect=test/quantization/pt2e/test_x86inductor_quantizer.py::TestQuantizePT2EX86Inductor::test_linear_reused_with_fusable_post_op
