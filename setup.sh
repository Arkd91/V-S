cat <<'EOF' > setup_and_run.sh
#!/bin/bash

set -e

# Install dependencies
sudo apt update && sudo apt install -y g++-9 python3-pip screen nano
pip3 install requests

# Clone and build VanitySearch
git clone https://github.com/FixedPaul/VanitySearch-Bitcrack.git
cd VanitySearch-Bitcrack
make
cd 'VanitySearch 2.2'
cd 'Compiled-Ubuntu 22.04-Cuda12'
chmod +x vanitysearch

# Get GPU model and IP
GPU_FULL=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n1)
GPU_MODEL=$(echo "$GPU_FULL" | grep -oP 'RTX\s*\K[0-9]+[a-zA-Z]*')
PUBLIC_IP=$(curl -s https://api.ipify.org)

# Get current date and hour in GMT-5 (Peru time)
JOIN_DATE=$(date -u -d '-5 hours' +"%Y%m%d")
JOIN_HOUR=$(date -u -d '-5 hours' +"%H%M")

WORKER_NAME="${GPU_MODEL}-${PUBLIC_IP}-${JOIN_DATE}-${JOIN_HOUR}"

# Write worker.py
cat <<EOPY > worker.py
import requests
import subprocess
import time
import threading
import sys

SERVER_URL = "https://project-bitcoin-puzzle.fly.dev/"
WORKER_NAME = "${WORKER_NAME}"
HEARTBEAT_INTERVAL = 10
VANITYSEARCH_CMD = "./vanitysearch"
TARGET_ADDRESS = "1PWo3JeB9jrGwfHDNpdGK54CRas7fsVzXU"
RANGE_BITS = 40

current_hex = None
stop_flag = False
match_found = False

def send_heartbeat():
    while not stop_flag and not match_found:
        try:
            res = requests.post(f"{SERVER_URL}/heartbeat", json={"worker": WORKER_NAME}, timeout=10)
            print(f"\\r[HEARTBEAT] {res.status_code}", end='', flush=True)
        except Exception as e:
            print(f"\\r[!] Heartbeat error: {e}", end='', flush=True)
        time.sleep(HEARTBEAT_INTERVAL)

def run_worker():
    global current_hex, stop_flag, match_found

    try:
        res = requests.post(f"{SERVER_URL}/join", json={"worker": WORKER_NAME}, timeout=10)
        print(f"[JOIN] {res.status_code} {res.text}")
    except Exception as e:
        print(f"[!] Failed to join server: {e}")
        sys.exit(1)

    threading.Thread(target=send_heartbeat, daemon=True).start()

    while not match_found:
        try:
            res = requests.post(f"{SERVER_URL}/request-work", json={"worker": WORKER_NAME}, timeout=10)

            if res.status_code != 200:
                print(f"[!] /request-work failed: {res.status_code} {res.text}")
                time.sleep(10)
                continue

            try:
                data = res.json()
            except Exception as e:
                print(f"[!] Invalid JSON response: {e} — Content: {res.text}")
                time.sleep(10)
                continue

            if data.get("message") == "Match already found. Stop all workers.":
                print("[✋] Match already found globally. Exiting.")
                break

            if "hex" not in data:
                print("[~] No work available. Waiting 60s...")
                time.sleep(60)
                continue

            current_hex = data["hex"]
            print(f"[+] Received work: {current_hex}")

            cmd = [
                VANITYSEARCH_CMD,
                "-gpuId", "0",
                "-start", current_hex,
                "-range", str(RANGE_BITS),
                TARGET_ADDRESS
            ]
            print(f"[+] Running: {' '.join(cmd)}")
            found = False

            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

            for line in proc.stdout:
                if "Found: 1" in line:
                    print("\\n[+] 🎯 MATCH FOUND")
                    found = True
                    proc.terminate()
                    break
                elif "MK/s" in line and "RUN:" in line:
                    print(f"\\r{line.strip()} ", end='', flush=True)
                elif "Setting starting keys..." in line:
                    print(f"\\r{line.strip()} ", end='', flush=True)
                else:
                    print(line, end='')

            proc.wait()

            result = "found" if found else "done"
            try:
                resp = requests.post(f"{SERVER_URL}/report-result", json={
                    "worker": WORKER_NAME,
                    "status": result,
                    "hex": current_hex
                }, timeout=10)
                if resp.ok:
                    print(f"\\n[+] Report accepted: {result}")
                else:
                    print(f"\\n[!] Report failed: {resp.status_code} {resp.text}")
            except Exception as e:
                print(f"[!] Failed to send report-result: {e}")

            if result == "found":
                match_found = True
                break

            current_hex = None
            time.sleep(2)

        except Exception as e:
            print(f"[!] Error during work loop: {e}")
            time.sleep(15)

if __name__ == "__main__":
    try:
        run_worker()
    except KeyboardInterrupt:
        stop_flag = True
        print("\\n[!] Stopped by user.")
EOPY

# Run the worker inside a screen session and attach
screen -S Mysession bash -c "python3 worker.py; echo '[!] Worker exited. Press Enter to close.'; read"
EOF

# Execute the script
chmod +x setup_and_run.sh && ./setup_and_run.sh
