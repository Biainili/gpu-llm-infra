# GPU LLM Inference Server — Ansible Playbook

Ansible automation for provisioning **Ubuntu 22.04 / 24.04 LTS** servers with **NVIDIA GPUs** and deploying a local LLM inference service exposed via a secured HTTP API.

Detailed verification results and execution logs from a live test server are documented in [TESTING.md](./TESTING.md).

## Architecture

```text
                       External Clients
                              |
                              v
  +-------------------------------------------------------+
  | Ubuntu 22.04 / 24.04 LTS                              |
  | UFW Firewall (Default Deny | Allow: 22/tcp, 80/tcp)   |
  |                                                       |
  |  +-------------------------------------------------+  |
  |  | Nginx Reverse Proxy (0.0.0.0:80, host network)  |  |
  |  |  - GET /health -> 200 OK                        |  |
  |  |  - Authorization: Bearer <token> (else 401)     |  |
  |  |  - Rate limit: 10r/s (burst 20)                 |  |
  |  |  - proxy_buffering off, read_timeout 300s       |  |
  |  +------------------------+------------------------+  |
  |                           |                           |
  |                           v                           |
  |  +-------------------------------------------------+  |
  |  | Ollama (127.0.0.1:11434)                        |  |
  |  |  - Model: qwen2.5:1.5b (configurable)           |  |
  |  |  - OpenAI API: /v1/chat/completions             |  |
  |  |  - Native API: /api/generate, /api/chat         |  |
  |  +------------------------+------------------------+  |
  |                           |                           |
  |  +------------------------v------------------------+  |
  |  | NVIDIA Driver 550 + NVIDIA Container Toolkit    |  |
  |  | (auto-detected via lspci; CPU fallback if none) |  |
  |  +-------------------------------------------------+  |
  |                                                       |
  |  +-------------------------------------------------+  |
  |  | Monitoring (127.0.0.1)                          |  |
  |  |  - node-exporter (:9100/metrics)                |  |
  |  |  - dcgm-exporter (:9400/metrics, when GPU=true) |  |
  |  +-------------------------------------------------+  |
  +-------------------------------------------------------+
```

## Features & Implementation Details

1. **Base Environment, Docker & NVIDIA Drivers (`common`, `docker`, `nvidia_gpu`):**
   * Base package installation, UTC timezone configuration, and UFW firewall hardening (default incoming policy set to `deny`; only SSH `22/tcp` and API Gateway `80/tcp` are allowed).
   * Official `docker-ce` and `docker-compose-plugin` (Compose v2) installation from Docker's APT repository. Any existing Snap Docker package is removed to prevent runtime conflicts with `nvidia-container-toolkit`.
   * Hardware auto-detection via `lspci` (`gpu_mode: "auto"`). When an NVIDIA GPU is detected, the playbook installs `linux-headers`, `nvidia-driver-550-server`, and `nvidia-container-toolkit`, configures `/etc/docker/daemon.json` via `nvidia-ctk`, triggers a reboot handler if the driver was newly installed, and verifies the card with `nvidia-smi`. On hosts without a physical GPU, the playbook automatically falls back to CPU execution.
2. **LLM Engine & Boot Persistence (`llm_engine`):**
   * Deploys **Ollama** via Docker Compose v2 with `restart: unless-stopped` and persistent weight storage in the `ollama_data` volume.
   * Idempotent model provisioning (`qwen2.5:1.5b`): queries `GET /api/tags` first and triggers `POST /api/pull` only if the target model is not already present on disk.
3. **API Security & Automated Healthchecks (`security_proxy`):**
   * Ollama is bound strictly to `127.0.0.1:11434` and is not directly reachable from external networks.
   * External traffic is terminated by **Nginx** on port `80` (`network_mode: host` to preserve client source IPs in `$binary_remote_addr` for rate limiting).
   * Enforces `Authorization: Bearer <llm_api_key>` authentication (`HTTP 401` on missing/invalid tokens), per-IP rate limiting (`10r/s`, `burst=20`), unbuffered streaming (`proxy_buffering off`), and an unauthenticated `/health` endpoint.
   * Runs built-in End-to-End smoke tests at the end of the playbook via `ansible.builtin.uri`: verifies `/health` (`200`), verifies unauthorized request rejection (`401`), and executes a live inference request against `/v1/chat/completions` (`200`).
4. **Monitoring (`monitoring`):**
   * Deploys `prom/node-exporter` (`127.0.0.1:9100/metrics`) for host telemetry.
   * Conditionally deploys `nvcr.io/nvidia/k8s/dcgm-exporter` (`127.0.0.1:9400/metrics`) when an NVIDIA GPU is present.

## Repository Structure

```text
gpu-llm-infra/
├── ansible.cfg
├── .ansible-lint
├── .yamllint
├── inventory/
│   └── hosts.ini
├── group_vars/
│   └── all.yml
├── playbooks/
│   └── site.yml
├── roles/
│   ├── common/
│   ├── docker/
│   ├── nvidia_gpu/
│   ├── llm_engine/
│   ├── security_proxy/
│   └── monitoring/
├── scripts/
│   └── smoke_test.sh
├── TESTING.md
└── README.md
```

## Configuration Variables (`group_vars/all.yml`)

| Variable | Default | Description |
| :--- | :--- | :--- |
| `gpu_mode` | `"auto"` | `"auto"` (detect via `lspci`), `"enabled"` (force GPU), `"disabled"` (force CPU) |
| `nvidia_driver_branch` | `"550"` | NVIDIA Server driver branch (`nvidia-driver-550-server`) |
| `llm_stack_dir` | `"/opt/llm-stack"` | Base directory for Docker Compose stacks on the target host |
| `ollama_bind_address` | `"127.0.0.1"` | Local bind address for the Ollama container |
| `ollama_port` | `11434` | Internal Ollama HTTP port |
| `llm_model_name` | `"qwen2.5:1.5b"` | Target LLM model to pull and serve |
| `api_gateway_port` | `80` | Public port exposed by the Nginx API Gateway |
| `llm_api_key` | `"sk-prod-gpu-llm-secret-token-2026"` | Bearer token required for API access |
| `nginx_rate_limit` | `"10r/s"` | Per-IP request rate limit |
| `monitoring_enabled` | `true` | Enable `node-exporter` and conditional `dcgm-exporter` |

## Usage

1. Set the target Ubuntu server IP address in [`inventory/hosts.ini`](./inventory/hosts.ini):
   ```ini
   [gpu_nodes]
   llm-node-01 ansible_host=<SERVER_IP> ansible_user=root ansible_port=22
   ```

2. Run the playbook (override the API token or model via `-e` / Ansible Vault in production):
   ```bash
   ansible-playbook -i inventory/hosts.ini playbooks/site.yml \
     -e "llm_api_key=sk-prod-gpu-llm-secret-token-2026"
   ```

3. Run specific roles using tags (`common`, `docker`, `nvidia`, `llm`, `security`, `monitoring`, `verify`):
   ```bash
   ansible-playbook -i inventory/hosts.ini playbooks/site.yml --tags "security,verify"
   ```

4. Run linters and syntax verification:
   ```bash
   yamllint . && ansible-lint && ansible-playbook -i inventory/hosts.ini playbooks/site.yml --syntax-check
   ```

## API Request Examples

Run the automated external smoke test suite using [`scripts/smoke_test.sh`](./scripts/smoke_test.sh):
```bash
./scripts/smoke_test.sh <SERVER_IP> sk-prod-gpu-llm-secret-token-2026 qwen2.5:1.5b
```

### 1. Healthcheck (unauthenticated)
```bash
curl -i http://<SERVER_IP>/health
```
```json
{"status":"healthy","service":"llm-api-gateway"}
```

### 2. Authentication Check (request without token -> HTTP 401)
```bash
curl -i http://<SERVER_IP>/api/tags
```
```json
{"error":"Unauthorized: valid Bearer token required"}
```

### 3. Chat Completion Request (OpenAI-compatible `/v1/chat/completions`)
```bash
curl -s http://<SERVER_IP>/v1/chat/completions \
  -H "Authorization: Bearer sk-prod-gpu-llm-secret-token-2026" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen2.5:1.5b",
    "messages": [
      {"role": "user", "content": "Hello! Who are you in one short sentence?"}
    ],
    "temperature": 0.2
  }' | jq .
```

### 4. Text Generation Request (Native Ollama `/api/generate`)
```bash
curl -s http://<SERVER_IP>/api/generate \
  -H "Authorization: Bearer sk-prod-gpu-llm-secret-token-2026" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen2.5:1.5b",
    "prompt": "Explain what DevOps is in one sentence.",
    "stream": false
  }' | jq .
```

### 5. Prometheus Metrics (on the host)
```bash
curl -s http://127.0.0.1:9100/metrics | head -n 20
curl -s http://127.0.0.1:9400/metrics | grep -E "DCGM_FI_DEV_(GPU_TEMP|GPU_UTIL|FB_USED)"
```
