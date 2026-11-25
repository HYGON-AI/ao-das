#!/usr/bin/env bash
# CI host capability report — emitted once per workflow run for runner inventory.
set +e
REPORT="${GITHUB_WORKSPACE:-/tmp}/ci-host-capability-report.txt"
{
  echo "===== HOST CAPABILITY REPORT $(date -u +%Y-%m-%dT%H:%M:%SZ) ====="
  echo "--- hostname"; hostname 2>&1
  echo "--- id"; id 2>&1
  echo "--- uname"; uname -a 2>&1
  echo "--- os-release"; head -4 /etc/os-release 2>&1
  echo "--- nproc / mem"; nproc 2>&1; free -g 2>/dev/null | head -2
  echo "--- nvidia-smi -L"; nvidia-smi -L 2>&1 | head -20
  echo "--- nvidia-smi csv"; nvidia-smi --query-gpu=name,uuid,memory.total,memory.free,driver_version --format=csv,noheader 2>&1 | head -20
  echo "--- rocm-smi"; rocm-smi 2>&1 | head -40
  echo "--- hy-smi"; hy-smi 2>&1 | head -60
  echo "--- hy-smi meminfo"; hy-smi --showmeminfo vram 2>&1 | head -30
  echo "--- accel devices"; ls -l /dev/kfd /dev/dri 2>&1
  echo "--- lspci"; lspci -nn 2>/dev/null | grep -iE 'VGA|Display|Processing accel|Hygon|AMD|NVIDIA' | head -20
  echo "--- dtk versions"; cat /opt/dtk/.info/rocm_version 2>/dev/null; cat /opt/dtk/.dtk_version 2>/dev/null
  echo "--- env"; env | grep -iE '^(HIP|ROCR|CUDA|HCU|DTK)' | head -20
  echo "===== END REPORT ====="
} 2>&1 | tee -a "$REPORT"
exit 0
