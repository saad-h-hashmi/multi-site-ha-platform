# Project Progress

Status labels: **VERIFIED** (executed and passed), **FAILED** (executed and failed), **NOT TESTED**, **SIMULATED** (see FINAL_STATUS.md).

| # | Phase | Status | Notes |
|---|---|---|---|
| 1 | Environment and project audit | Done (2026-11-21) | `docs/ENVIRONMENT_AUDIT.md`, `docs/ARCHITECTURE_DECISIONS.md`, `docs/RESOURCE_PLAN.md` |
| – | Host bootstrap automation | Written, waiting for the owner to run it | `make bootstrap` needs the sudo password (sudo is not passwordless) |
| 2 | Architecture design | In progress | |
| 3 | Network build | Not started | |
| 4 | Kubernetes platform | Not started | |
| 5 | Automation and rebuild | Not started | |
| 6 | Demo application | Not started | |
| 7 | HA and failure testing | Not started | |
| 8 | Monitoring and logging | Not started | |
| 9 | Security | Not started | |
| 10 | Documentation | Not started | |
| 11 | Diagrams and evidence | Not started | |
| 12 | GitHub and quality | Local commits only | No push credentials on the VM |
| 13 | Final validation | Not started | |

## Log

* **2026-11-21:** Audited the VM: 2 vCPU, 9 GiB RAM, 6.3 GB free disk, no nested virtualisation, Apache on :80, Docker/kubectl missing. Preserved the brief as `PROJECT_BRIEF.md`. Chose an architecture of containerised sites plus K3s with 3 servers and 3 agents. Wrote the host bootstrap playbook.
