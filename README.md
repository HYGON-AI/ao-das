<div align="center">

# TorchAO for HCU

</div>

## Open Source Attribution
This repository is based on [torchao](https://github.com/pytorch/ao.git) and contains some changes for HCU/ROCm environments. Torchao is derived from the upstream torchao project.

- Direct upstream: [torchao](https://github.com/pytorch/ao.git)
- Upstream tag: v0.18.0
- Upstream baseline commit: 5f2baf9d575cf732362594c998c399902942531f
- Third-party inventory: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)
- License: BSD-3-Clause
- Upstream-derived historical reference: [README_ORIGIN.md](README_ORIGIN.md)

## Modification Scope
The changes adapt quantization for HCU/ROCm. Unless explicitly stated otherwise, upstream-originated files remain governed by their inherited BSD-3-Clause license terms.

Modified by Hygon Information Technology Co., Ltd.

## Build and Installation
### Requirements
- Python >= 3.10
- PyTorch built for the target HCU environment, Pytorch >= 2.10
- Vllm built for the target HCU environment
- Torchvision built for the target HCU environment
- Lightop built for the target HCU environment
- Triton built for the target HCU environment

### Build from Source
```bash
git submodule update --init --recursive
python setup.py bdist_wheel
```
`setup.py` uses `ROCM_PATH` when set and otherwise defaults to `/opt/dtk`.

## Testing and Accuracy
Run the public torchao test suite on an HCU device:
```bash
python -m pytest test -vs
```

## References

- [torchao direct upstream](https://github.com/pytorch/ao.git)
- [Upstream-derived historical reference](README_ORIGIN.md)

## License
BSD-3-Clause License
Additional modifications copyright: Copyright 2026 Hygon Information Technology Co., Ltd.
