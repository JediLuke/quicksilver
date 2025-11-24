# Quicksilver Troubleshooting Guide

## Table of Contents
- [Model Loading Issues](#model-loading-issues)
- [Memory/Swap Problems](#memoryswap-problems)
- [llama.cpp Version Compatibility](#llamacpp-version-compatibility)
- [Backend Configuration](#backend-configuration)
- [Common Error Messages](#common-error-messages)

---

## Model Loading Issues

### Symptom: "error: invalid argument:" from llama-server

**Diagnosis:**
```bash
# Check llama.cpp version
/home/luke/workbench/tools/llama.cpp/build/bin/llama-server --version

# Try loading the model
/home/luke/workbench/tools/llama.cpp/build/bin/llama-server \
  -m /path/to/your/model.gguf \
  --port 8080 \
  -ngl 99

# If you see "error: invalid argument:" immediately, this is a version mismatch
```

**Root Cause:**
- Your llama.cpp version is too old for the model format
- GGUF format evolves with new model releases
- Example: Llama 3.3 (Dec 2024) requires llama.cpp newer than version 5974 (July 2024)

**Solution: Update and Rebuild llama.cpp**

```bash
# 1. Navigate to llama.cpp directory
cd /home/luke/workbench/tools/llama.cpp

# 2. Save your current version (optional backup)
git branch backup-$(date +%Y%m%d)

# 3. Update to latest
git fetch origin
git checkout master
git pull origin master

# 4. Clean previous build
rm -rf build
mkdir build
cd build

# 5. Configure with CUDA support
cmake .. \
  -DGGML_CUDA=ON \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CUDA_ARCHITECTURES=89  # For RTX 4090, adjust if different GPU

# 6. Build (use all CPU cores)
cmake --build . --config Release -j$(nproc)

# 7. Verify installation
./bin/llama-server --version
# Should show a much higher version number

# 8. Test with your model
./bin/llama-server \
  -m /home/luke/workbench/models/Llama-3.3-70B-Instruct-Q4_K_M.gguf \
  --port 8080 \
  -ngl 99 \
  --host 127.0.0.1

# Wait for it to load (may take 30-60 seconds for 70B models)
# Then check health:
curl http://localhost:8080/health
```

**GPU Architecture Reference:**
- RTX 4090: `-DCMAKE_CUDA_ARCHITECTURES=89`
- RTX 3090/3080: `-DCMAKE_CUDA_ARCHITECTURES=86`
- RTX 2080/2070: `-DCMAKE_CUDA_ARCHITECTURES=75`
- Check your GPU: `nvidia-smi --query-gpu=compute_cap --format=csv`

---

## Memory/Swap Problems

### Symptom: System using 100% swap, system becomes unresponsive

**Diagnosis:**
```bash
# Check memory usage
free -h

# Look for high swap usage:
# Swap:    8.0Gi    7.9Gi    138Mi   <- BAD! 99% swap used

# Check for runaway llama processes
ps aux | grep llama

# Check GPU memory usage
nvidia-smi
```

**Root Causes:**

1. **Model not loading to GPU (most common)**
   - llama.cpp version mismatch (see above)
   - Not enough VRAM (40GB Q4_K_M 70B needs ~40GB VRAM)
   - GPU layers not specified (`-ngl` parameter)

2. **Too many concurrent model loading attempts**
   - Multiple failed starts filling RAM
   - Background processes still running

3. **Context size too large**
   - Large `ctx_size` (8192+) with CPU inference = massive RAM usage

**Immediate Recovery:**

```bash
# 1. Kill all llama processes
killall -9 llama-server llama-cli llama-run

# 2. Clear swap (requires sudo)
sudo swapoff -a
sudo swapon -a

# 3. Check memory is recovered
free -h

# 4. Check no zombie processes
ps aux | grep llama
```

**Prevention:**

```elixir
# config/config.exs
config :quicksilver,
  llama_cpp: %{
    # Prevent auto-start to avoid automatic failed loads
    auto_start: false,

    # Ensure GPU offloading
    gpu_layers: 99,  # Or higher for full GPU offload

    # Reasonable context size
    ctx_size: 4096,  # Start smaller, increase as needed
  }
```

**Testing GPU Offload:**

```bash
# Start server manually with GPU monitoring
watch -n 1 nvidia-smi  # In one terminal

# In another terminal:
/home/luke/workbench/tools/llama.cpp/build/bin/llama-server \
  -m /path/to/model.gguf \
  -ngl 99 \
  --port 8080

# You should see GPU memory usage increase in nvidia-smi
# Model should load into VRAM, NOT system RAM
```

---

## llama.cpp Version Compatibility

### Version Requirements by Model

| Model Family | Release Date | Min llama.cpp Version | Git Commit Hash |
|--------------|--------------|----------------------|-----------------|
| Llama 3.3    | Dec 2024     | ~6500+              | Latest master   |
| Llama 3.2    | Sep 2024     | ~4000+              | b3909          |
| Llama 3.1    | Jul 2024     | ~3500+              | Latest master   |
| Qwen 2.5     | Sep 2024     | ~4000+              | b3909          |
| Mistral 0.3  | May 2024     | ~2500+              | Latest master   |

**Check Compatibility:**

```bash
# Get your llama.cpp version
/path/to/llama-server --version

# Example output:
# version: 5974 (a12363bb)  <- This is from July 2024
#          ^^^^
#          This number needs to be higher than the model requirement

# Get model info
/path/to/llama-gguf-info /path/to/model.gguf | head -50
```

**Update Schedule Recommendation:**
- Update llama.cpp monthly if using latest models
- Pin to specific version in production
- Test updates in development first

---

## Backend Configuration

### Auto-Start vs Manual Start

**Use Auto-Start (default) when:**
- Production environment with stable model
- Single model that rarely changes
- Want immediate availability

```elixir
# config/config.exs
llama_cpp: %{
  auto_start: true,  # or omit - defaults to true
  model_file: "stable-model.gguf"
}
```

**Use Manual Start when:**
- Experimenting with different models
- Large models that take time to load
- Want control over when resources are used
- Debugging model loading issues

```elixir
# config/config.exs
llama_cpp: %{
  auto_start: false,
  model_file: "Llama-3.3-70B-Instruct-Q4_K_M.gguf"
}
```

Then start manually:
```elixir
# In IEx
iex> Quicksilver.Backends.LlamaCpp.start_standalone()

# Or check if already running:
iex> Quicksilver.Backends.LlamaCpp.server_running?()
true

# Connect to existing server:
iex> Quicksilver.Backends.LlamaCpp.initialize()
```

### Backend Status Checks

```elixir
# Check if server process exists
iex> Quicksilver.Backends.LlamaCpp.server_running?()
true

# Check if server is healthy and ready
iex> Quicksilver.Backends.LlamaCpp.health_check(LlamaCpp)
:ok

# Get backend state
iex> :sys.get_state(LlamaCpp)
%Quicksilver.Backends.LlamaCpp{
  ready: true,
  owned_server: false,
  ...
}
```

### Manual Server Management

```bash
# Start standalone server (persists across Quicksilver restarts)
iex> Quicksilver.Backends.LlamaCpp.start_standalone()

# Stop standalone server
iex> Quicksilver.Backends.LlamaCpp.stop_standalone()

# Start managed server (stops when Quicksilver exits)
iex> Quicksilver.Backends.LlamaCpp.start_owned_server()

# Force kill any server on the port
iex> Quicksilver.Backends.LlamaCpp.force_shutdown_server()

# Check what's using port 8080
System.cmd("lsof", ["-ti", ":8080"])
```

---

## Common Error Messages

### "Backend not ready"

**Meaning:** The LlamaCpp backend hasn't finished initializing

**Solutions:**
```elixir
# Check backend status
iex> Quicksilver.Backends.LlamaCpp.health_check(LlamaCpp)

# If returns {:error, :not_ready}, wait for model to load
# Large models (70B) can take 30-60 seconds

# If still not ready after 2 minutes, check logs:
# Look for errors in the terminal where you started Quicksilver

# Force re-initialization
iex> Quicksilver.Backends.LlamaCpp.initialize()
```

### "Model not found at /path/to/model.gguf"

**Check:**
```bash
# Verify file exists
ls -lh /home/luke/workbench/models/Llama-3.3-70B-Instruct-Q4_K_M.gguf

# Check config path matches
iex> Application.get_env(:quicksilver, :llama_cpp)
%{
  model_path: "/home/luke/workbench/models/",
  model_file: "Llama-3.3-70B-Instruct-Q4_K_M.gguf",
  ...
}

# Full path should be model_path + "/" + model_file
# Note: Quicksilver handles the "/" concatenation
```

### "Connection refused" or "Port already in use"

**Diagnosis:**
```bash
# Check what's using the port
lsof -i :8080

# If another llama-server is running:
killall llama-server

# Or kill specific PID:
kill -9 <PID>

# Then restart Quicksilver
```

### "Out of memory" or system freeze

**See [Memory/Swap Problems](#memoryswap-problems) section above**

### "error: invalid argument:"

**See [Model Loading Issues](#model-loading-issues) section above**

---

## Debugging Workflow

### Step-by-Step Diagnosis

1. **Verify llama.cpp works standalone:**
```bash
cd /home/luke/workbench/tools/llama.cpp/build/bin

# Test with llama-run (simpler than server)
echo "Hello" | ./llama-run /path/to/model.gguf

# Should see model load and generate text
# If this fails, problem is llama.cpp/model, not Quicksilver
```

2. **Test llama-server directly:**
```bash
# Start server manually with verbose output
./llama-server \
  -m /path/to/model.gguf \
  --port 8080 \
  -ngl 99 \
  --host 127.0.0.1 \
  -c 4096

# In another terminal, test health:
curl http://localhost:8080/health

# Should return: {"status":"ok"}
```

3. **Test Quicksilver connection:**
```elixir
# Start Quicksilver with auto_start: false
iex -S mix

# Server should already be running from step 2
# Try to connect:
iex> Quicksilver.Backends.LlamaCpp.initialize()
:ok

# Test completion:
iex> Quicksilver.Backends.LlamaCpp.complete(
  LlamaCpp,
  [%{role: "user", content: "Say hello"}]
)
{:ok, "Hello! How can I help you today?"}
```

4. **Check logs and state:**
```elixir
# Get detailed backend state
iex> :sys.get_state(LlamaCpp) |> IO.inspect(limit: :infinity)

# Check recent log messages
# Look in terminal output for:
# - [info] messages about server status
# - [error] messages about failures
# - [warning] messages about timeouts
```

---

## Performance Tuning

### Model Loading Time

**Factors affecting load time:**
- Model size (70B takes longer than 7B)
- Quantization (Q4 loads faster than FP16)
- GPU layers (`-ngl` setting)
- Storage speed (NVMe > SATA SSD > HDD)

**Optimization:**
```elixir
# config/config.exs
llama_cpp: %{
  # More GPU layers = faster, but needs VRAM
  gpu_layers: 99,  # Try increasing if you have VRAM

  # Smaller context = faster initial load
  ctx_size: 4096,  # Increase only if needed

  # More threads helps with CPU-side processing
  threads: 16,  # Match your CPU core count
}
```

**Monitor loading:**
```bash
# Watch GPU memory during load
watch -n 0.5 nvidia-smi

# Should see VRAM usage climb steadily
# 70B Q4_K_M should reach ~40GB VRAM when loaded
```

### Memory Usage

**Expected VRAM for common quantizations:**
- 70B Q4_K_M: ~40GB
- 70B Q8: ~75GB (won't fit on single RTX 4090)
- 32B Q4_K_M: ~18GB
- 7B Q4_K_M: ~4GB

**If not enough VRAM:**
```elixir
# Reduce GPU layers to fit available VRAM
llama_cpp: %{
  gpu_layers: 60,  # Use less than 99
  # Some layers will run on CPU (slower but works)
}
```

**Check actual memory usage:**
```bash
# GPU memory
nvidia-smi --query-gpu=memory.used,memory.total --format=csv

# System memory
free -h

# Per-process memory
ps aux | grep llama-server
```

---

## Getting Help

### Information to Collect

When reporting issues, include:

1. **System Info:**
```bash
# OS and kernel
uname -a

# GPU info
nvidia-smi

# Available memory
free -h

# Disk space
df -h /home/luke/workbench/models
```

2. **llama.cpp Version:**
```bash
/path/to/llama-server --version
```

3. **Model Info:**
```bash
ls -lh /path/to/model.gguf
# Include file size and date

# Model metadata (if llama-gguf-info available)
/path/to/llama-gguf-info /path/to/model.gguf | head -50
```

4. **Quicksilver Config:**
```elixir
iex> Application.get_env(:quicksilver, :llama_cpp)
```

5. **Error Messages:**
- Copy full error output from terminal
- Include timestamps if possible
- Note when the error occurred in the process

6. **Logs:**
```bash
# If running as service, check logs
journalctl -u quicksilver -n 100

# Or include terminal output from when you started Quicksilver
```

### Common Solutions Summary

| Problem | Quick Fix |
|---------|-----------|
| Model won't load | Update llama.cpp |
| System using swap | Kill llama processes, check GPU layers |
| Backend not ready | Wait 1-2 minutes for large models |
| Port in use | `killall llama-server` |
| Connection refused | Check if server started with `lsof -i :8080` |
| Slow performance | Increase `gpu_layers`, reduce `ctx_size` |
| Out of VRAM | Reduce `gpu_layers` or use smaller model |

---

## Additional Resources

- **llama.cpp Documentation:** https://github.com/ggerganov/llama.cpp
- **GGUF Format Spec:** https://github.com/ggerganov/ggml/blob/master/docs/gguf.md
- **Quicksilver Issues:** https://github.com/[your-repo]/quicksilver/issues
- **Model Sources:**
  - Hugging Face: https://huggingface.co/models?library=gguf
  - TheBloke: https://huggingface.co/TheBloke

---

## Maintenance Checklist

### Weekly (if using latest models)
- [ ] Check for llama.cpp updates
- [ ] Monitor swap usage
- [ ] Clear old model files if space limited

### Monthly
- [ ] Update llama.cpp to latest stable
- [ ] Review and optimize config
- [ ] Check model compatibility

### When Switching Models
- [ ] Stop current server
- [ ] Update config/config.exs
- [ ] Test new model standalone first
- [ ] Monitor memory during first load
- [ ] Update this document if issues found

---

*Last Updated: 2025-01-20*
*Quicksilver Version: 0.1.0*
*llama.cpp Tested: 5974-6500+*
