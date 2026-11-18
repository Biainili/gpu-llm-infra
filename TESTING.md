# Verification & Testing Report (`TESTING.md`)

Verification summary and execution logs from testing the playbook on an Ubuntu 24.04 LTS server.

## 1. Test Environment

* **Instance:** Hetzner Cloud `CPX22` (2 vCPU, 4 GB RAM, 80 GB NVMe)
* **OS:** Ubuntu 24.04 LTS (`noble`, Linux kernel `6.8.0-138-generic`)
* **Tooling:** `ansible-core 2.16.3`, `ansible-lint 6.17.2`, `yamllint 1.33.0`

Because standard hourly cloud VMs do not attach a physical NVIDIA PCI GPU, verification was conducted in two phases:
1. **Live Runtime Verification (`gpu_mode: auto`):** full deployment on a clean Ubuntu 24.04 server (UFW, Docker CE, Ollama, `qwen2.5:1.5b` model pull, Nginx reverse proxy with Bearer token auth and rate limiting, `node-exporter`, and built-in E2E API assertions), followed by an idempotency run (`changed=0`) and a full OS `reboot` persistence test.
2. **GPU Branch Verification (`-e gpu_mode=enabled --check --diff`):** verified APT dependency resolution for `nvidia-driver-550-server` and `linux-headers`, `nvidia-container-toolkit` repository configuration, reboot handler notification, and Jinja2 template diffs injecting `driver: nvidia` GPU device reservations and `dcgm-exporter`.

---

## 2. Verification Logs

### 2.1. Static Analysis & Syntax Check

```bash
$ yamllint . && ansible-lint && ansible-playbook -i inventory/hosts.ini playbooks/site.yml --syntax-check

Passed: 0 failure(s), 0 warning(s) on 37 files. Profile 'production' was required, but only 'production' profile passed.

playbook: playbooks/site.yml
```

### 2.2. Initial Provisioning & Built-in E2E Smoke Test

```bash
$ ansible-playbook -i inventory/hosts.ini playbooks/site.yml
...
TASK [common : Report detected execution mode] ************************************
ok: [llm-node-01] => {
    "msg": "GPU Mode configuration is 'auto'. Effective NVIDIA GPU active state: False (CPU Fallback Mode)."
}
...
TASK [llm_engine : Pull target LLM model idempotently if not already present] *****
changed: [llm-node-01]
...
TASK [security_proxy : Verify public /health endpoint returns HTTP 200 OK] ********
ok: [llm-node-01]

TASK [security_proxy : Verify unauthenticated API request is rejected with HTTP 401 Unauthorized] ***
ok: [llm-node-01]

TASK [security_proxy : Verify authenticated OpenAI-compatible inference request succeeds (HTTP 200)] ***
ok: [llm-node-01]

TASK [security_proxy : Report End-to-End LLM Inference verification result] *******
ok: [llm-node-01] => {
    "msg": "E2E Verification Passed! Healthcheck: HTTP 200 | Unauthenticated Block: HTTP 401 | Authenticated LLM Response (qwen2.5:1.5b): \"READY\""
}
...
PLAY RECAP ************************************************************************
llm-node-01                : ok=38   changed=22   unreachable=0    failed=0    skipped=10   rescued=0    ignored=0   
```

### 2.3. Second Run (Idempotency Test)

```bash
$ ansible-playbook -i inventory/hosts.ini playbooks/site.yml
...
TASK [llm_engine : Pull target LLM model idempotently if not already present] *****
skipping: [llm-node-01]

TASK [security_proxy : Report End-to-End LLM Inference verification result] *******
ok: [llm-node-01] => {
    "msg": "E2E Verification Passed! Healthcheck: HTTP 200 | Unauthenticated Block: HTTP 401 | Authenticated LLM Response (qwen2.5:1.5b): \"READY\""
}
...
PLAY RECAP ************************************************************************
llm-node-01                : ok=34   changed=0    unreachable=0    failed=0    skipped=11   rescued=0    ignored=0   
```

### 2.4. NVIDIA GPU Branch Verification (`--check --diff -e gpu_mode=enabled`)

```bash
$ ansible-playbook -i inventory/hosts.ini playbooks/site.yml -e gpu_mode=enabled --check --diff
...
TASK [common : Report detected execution mode] ************************************
ok: [llm-node-01] => {
    "msg": "GPU Mode configuration is 'enabled'. Effective NVIDIA GPU active state: True (GPU Hardware Mode)."
}

TASK [nvidia_gpu : Install Linux kernel headers and NVIDIA Server driver] *********
The following NEW packages will be installed:
  dkms ... linux-headers-6.8.0-138 linux-headers-6.8.0-138-generic ...
  nvidia-driver-550-server ...
0 upgraded, 74 newly installed, 0 to remove and 128 not upgraded.
changed: [llm-node-01]

TASK [nvidia_gpu : Add NVIDIA Container Toolkit APT repository] *******************
--- before: /dev/null
+++ after: /etc/apt/sources.list.d/nvidia-container-toolkit.list
@@ -0,0 +1 @@
+deb [signed-by=/etc/apt/keyrings/nvidia-container-toolkit.asc] https://nvidia.github.io/libnvidia-container/stable/deb/$(ARCH) /
changed: [llm-node-01]

RUNNING HANDLER [nvidia_gpu : Reboot server for nvidia driver] ********************
changed: [llm-node-01]

TASK [llm_engine : Render Ollama Docker Compose configuration] ********************
--- before: /opt/llm-stack/ollama/docker-compose.yml
+++ after: docker-compose.yml.j2
@@ -11,6 +11,14 @@
       - OLLAMA_KEEP_ALIVE=24h
     volumes:
       - ollama_data:/root/.ollama
+    deploy:
+      resources:
+        reservations:
+          devices:
+            - driver: nvidia
+              count: all
+              capabilities:
+                - gpu

TASK [monitoring : Render monitoring Docker Compose configuration] ****************
--- before: /opt/llm-stack/monitoring/docker-compose.yml
+++ after: docker-compose.yml.j2
@@ -15,3 +15,20 @@
+  dcgm_exporter:
+    image: nvcr.io/nvidia/k8s/dcgm-exporter:3.3.8-3.6.0-ubuntu22.04
+    container_name: dcgm-exporter
+    restart: unless-stopped
+    ports:
+      - "127.0.0.1:9400:9400"
+    cap_add:
+      - SYS_ADMIN
+    deploy:
+      resources:
+        reservations:
+          devices:
+            - driver: nvidia
+              count: all
+              capabilities:
+                - gpu

PLAY RECAP ************************************************************************
llm-node-01                : ok=30   changed=6    unreachable=0    failed=0    skipped=18   rescued=0    ignored=0   
```

### 2.5. Reboot Persistence & External API Verification

After issuing a system `reboot` on the target server and waiting 35 seconds for boot completion, external requests were executed against the server without re-running Ansible (automated in [`scripts/smoke_test.sh`](./scripts/smoke_test.sh)):

```text
=== 1. Healthcheck (/health) ===
HTTP/1.1 200 OK
Server: nginx
Content-Type: application/json

{"status":"healthy","service":"llm-api-gateway"}

=== 2. Unauthorized Access Check (expect HTTP 401) ===
HTTP/1.1 401 Unauthorized
Server: nginx
Content-Type: application/json

{"error":"Unauthorized: valid Bearer token required"}

=== 3. Authenticated LLM Inference After Reboot ===
{"id":"chatcmpl-755","object":"chat.completion","created":1795002383,"model":"qwen2.5:1.5b","system_fingerprint":"fp_ollama","choices":[{"index":0,"message":{"role":"assistant","content":"I am an artificial intelligence designed to assist with various tasks and answer questions to the best of my knowledge."},"finish_reason":"stop"}],"usage":{"prompt_tokens":39,"prompt_tokens_details":{"cached_tokens":0},"completion_tokens":22,"total_tokens":61}}
```
