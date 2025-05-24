from flask import Flask, request, jsonify
import duckdb
import time
import threading
import requests

# === Telegram Bot Tokens and Chat IDs ===
BOT_A_TOKEN = "7565815877:AAEN8dj3-cxBiWR1OCzQe8JvAMZvKMOKxzQ"
BOT_A_CHAT_ID = "5719338492"

BOT_B_TOKEN = "7418564051:AAFYhx6oDowNDBZZcmzwFx3PS-ecFfMql8Q"
BOT_B_CHAT_ID = "5719338492"

# === Server setup ===
app = Flask(__name__)
DB_FILE = "/data/hex_ranges.duckdb"
db_lock = threading.Lock()

# === Internal state ===
workers = {}  # {worker_id: {"last_seen": timestamp, "hex": current_range}}
heartbeat_timeout = 180  # seconds

# === Telegram with retry ===
def send_telegram(bot_token, chat_id, message, retries=3):
    url = f"https://api.telegram.org/bot{bot_token}/sendMessage"
    for i in range(retries):
        try:
            response = requests.post(url, data={"chat_id": chat_id, "text": message}, timeout=10)
            if response.ok:
                print(f"[Telegram] ✅ Sent: {message}")
                return
            else:
                print(f"[Telegram] ❌ HTTP {response.status_code}: {response.text}")
        except Exception as e:
            print(f"[Telegram] ❌ Exception (attempt {i+1}): {e}")
        time.sleep(1)

# === Worker joins ===
@app.route("/join", methods=["POST"])
def join():
    worker = request.json.get("worker")
    if not worker:
        return jsonify({"error": "Missing worker name"}), 400

    workers[worker] = {"last_seen": time.time(), "hex": None}
    send_telegram(BOT_B_TOKEN, BOT_B_CHAT_ID, f"👋 {worker} joined.\nActive: {list(workers.keys())}\nTotal {len(workers)}")
    return jsonify({"message": f"{worker} registered"})

# === Request work ===
@app.route("/request-work", methods=["POST"])
def request_work():
    worker = request.json.get("worker")
    if not worker:
        return jsonify({"error": "Missing worker name"}), 400

    if worker in workers:
        workers[worker]["last_seen"] = time.time()

    with db_lock:
        with duckdb.connect(DB_FILE) as con:
            match_count = con.execute("SELECT COUNT(*) FROM work_ranges WHERE status = 'found'").fetchone()[0]
            if match_count > 0:
                return jsonify({"message": "Match already found. Stop all workers."})

            result = con.execute("SELECT id, hex FROM work_ranges WHERE status = 'pending' ORDER BY id ASC LIMIT 1").fetchone()
            if result:
                hex_id, hex_value = result
                con.execute("UPDATE work_ranges SET status = 'in_progress', worker = ? WHERE id = ?", (worker, hex_id))
                workers[worker]["hex"] = hex_value

                total = con.execute("SELECT COUNT(*) FROM work_ranges").fetchone()[0]
                index = hex_id

                send_telegram(BOT_A_TOKEN, BOT_A_CHAT_ID, f"🚀 Starting Range {index}/{total}\n{hex_value}\n👷 {worker}")
                return jsonify({"hex": hex_value, "range_bits": 40})
            else:
                return jsonify({"message": "No pending work"}), 200

# === Heartbeat ===
@app.route("/heartbeat", methods=["POST"])
def heartbeat():
    worker = request.json.get("worker")
    if worker in workers:
        workers[worker]["last_seen"] = time.time()
        return jsonify({"message": "Heartbeat received"})
    return jsonify({"error": "Unknown worker"}), 400

# === Report result ===
@app.route("/report-result", methods=["POST"])
def report_result():
    worker = request.json.get("worker")
    status = request.json.get("status")  # 'found' or 'done'
    hex_value = request.json.get("hex")

    if not all([worker, status, hex_value]):
        return jsonify({"error": "Missing fields"}), 400

    if worker not in workers:
        return jsonify({"error": "Unknown worker"}), 400

    workers[worker]["last_seen"] = time.time()
    print(f"[REPORT] {worker} reported '{status}' for {hex_value}")

    with db_lock:
        with duckdb.connect(DB_FILE) as con:
            con.execute("UPDATE work_ranges SET status = ?, worker = ? WHERE hex = ?", (status, worker, hex_value))
            con.execute("CHECKPOINT;")

            index = con.execute("SELECT id FROM work_ranges WHERE hex = ?", (hex_value,)).fetchone()[0]
            total = con.execute("SELECT COUNT(*) FROM work_ranges").fetchone()[0]

    if status == "found":
        send_telegram(BOT_A_TOKEN, BOT_A_CHAT_ID, f"✅ MATCH FOUND by {worker}!\n{hex_value}")
        send_telegram(BOT_B_TOKEN, BOT_B_CHAT_ID, f"🛑 MATCH found — all workers should stop.")
    else:
        send_telegram(BOT_A_TOKEN, BOT_A_CHAT_ID, f"❌ Range {index}/{total} finished with no match\n👷 {worker}")

    return jsonify({"message": "Result recorded"})

# === Monitor dead workers ===
def monitor_workers():
    print("[Monitor] Started worker monitoring thread")
    counter = 0
    while True:
        now = time.time()
        to_remove = []

        for worker, info in list(workers.items()):
            age = now - info["last_seen"]
            print(f"[Monitor] Checking {worker}: last seen {age:.1f}s ago")
            if age > heartbeat_timeout:
                print(f"[Monitor] {worker} timed out (last seen {age:.1f}s ago)")
                to_remove.append(worker)

        if to_remove:
            with db_lock:
                with duckdb.connect(DB_FILE) as con:
                    for w in to_remove:
                        con.execute("UPDATE work_ranges SET status = 'pending', worker = NULL WHERE worker = ? AND status = 'in_progress'", (w,))
                        del workers[w]
                        send_telegram(BOT_B_TOKEN, BOT_B_CHAT_ID, f"❌ {w} is not responding.\nRemaining: {list(workers.keys())}\nTotal {len(workers)}")

        counter += 1
        if counter % 18 == 0:  # Every 3 minutes
            with db_lock:
                with duckdb.connect(DB_FILE) as con:
                    con.execute("CHECKPOINT;")

        time.sleep(10)

# Start monitor thread
threading.Thread(target=monitor_workers, daemon=True).start()

# Health check
@app.route("/", methods=["GET"])
def home():
    return "✅ Server is running", 200
