import subprocess
import time
import socket
import os
import signal
import sys
import threading

binary = "./zig-out/bin/simpledb"

def start_node(port, seeds):
    cmd = [binary, "--port", str(port), "--data-dir", "@data"]

    if seeds:
        for seed in seeds.split(","):
            cmd.append("--seed")
            cmd.append(seed)
    
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, preexec_fn=os.setsid)
    return p

nodes = {}

os.system("rm -rf @data/ && mkdir -p @data/")

print("Starting Node 1 (8081)...")
nodes[8081] = start_node(8081, "")
time.sleep(1)

print("Starting Node 2 (8082)...")
nodes[8082] = start_node(8082, "127.0.0.1:8081")
time.sleep(1)

print("Starting Node 3 (8083)...")
nodes[8083] = start_node(8083, "127.0.0.1:8081,127.0.0.1:8082")
time.sleep(2)

def send_query(port, query, expect_ok=True, timeout=2):
    try:
        s = socket.create_connection(("127.0.0.1", port), timeout=timeout)
        s.sendall((query + "\r\n").encode())
        resp = s.recv(4096).decode()
        s.close()
        if expect_ok and "OK" not in resp and "already exists" not in resp:
            return False, resp
        return True, resp
    except Exception as e:
        return False, str(e)

def find_leader():
    for port in [8081, 8082, 8083]:
        success, resp = send_query(port, "BEGIN", expect_ok=False)
        if success and "OK" in resp:
            send_query(port, "ROLLBACK")
            return port
        if success and "already in transaction" in resp:
            send_query(port, "ROLLBACK")
            return port
    return None

leader = None
for _ in range(5):
    leader = find_leader()
    if leader:
        break
    print("Waiting for leader election...")
    time.sleep(2)

if not leader:
    print("Failed to find a leader!")
    for p in nodes.values():
        os.killpg(os.getpgid(p.pid), signal.SIGKILL)
    sys.exit(1)

print(f"Found leader at port {leader}")

print("Creating test table...")
succ, resp = send_query(leader, "CREATE TABLE chaos_tbl (id INT, val VARCHAR)")
print(f"CREATE TABLE resp: {resp.strip()}")

print("Upgrading cluster to Explicit Joint Consensus Configuration...")
send_query(leader, "RAFT_CONFIG_UPDATE add 127.0.0.1:8081")
send_query(leader, "RAFT_CONFIG_UPDATE add 127.0.0.1:8082")
send_query(leader, "RAFT_CONFIG_UPDATE add 127.0.0.1:8083")
time.sleep(2)

insert_count = 0
running = True

def inserter():
    global insert_count
    current_leader = leader
    while running:
        query = f"INSERT INTO chaos_tbl VALUES ({insert_count}, 'data_{insert_count}')"
        success, resp = send_query(current_leader, query, timeout=1)
        if not success:
            print(f"Insert fail: {resp.strip()}")
            time.sleep(1)
            new_leader = find_leader()
            if new_leader:
                current_leader = new_leader
        else:
            insert_count += 1
            time.sleep(0.1)

print("Starting background writes...")
t = threading.Thread(target=inserter)
t.start()

time.sleep(2)
print(f"Inserts so far: {insert_count}")

# Chaos 1: Pause a follower
followers = [p for p in [8081, 8082, 8083] if p != leader]
victim = followers[0]
print(f"Chaos: SIGSTOP on follower {victim}")
os.killpg(os.getpgid(nodes[victim].pid), signal.SIGSTOP)

time.sleep(3)
print(f"Inserts so far: {insert_count} (Should still be increasing, majority is 2/3)")

print(f"Chaos: Resuming follower {victim}")
os.killpg(os.getpgid(nodes[victim].pid), signal.SIGCONT)
time.sleep(2) # Give it time to catch up

# Chaos 2: Pause the leader
old_leader = leader
print(f"Chaos: SIGSTOP on LEADER {old_leader}")
os.killpg(os.getpgid(nodes[old_leader].pid), signal.SIGSTOP)

print("Waiting for cluster to elect new leader...")
time.sleep(5)
new_leader = find_leader()
print(f"New leader is {new_leader}")

print("Waiting for inserts to resume...")
time.sleep(4)
print(f"Inserts so far: {insert_count} (Should resume on new leader)")

print("Chaos: Resuming old leader")
os.killpg(os.getpgid(nodes[old_leader].pid), signal.SIGCONT)

time.sleep(5)
print(f"Final insert count: {insert_count}")
running = False
t.join()

print("Verifying data consistency across all nodes...")
time.sleep(2)

def get_count(port):
    success, resp = send_query(port, "SELECT id FROM chaos_tbl", expect_ok=False)
    if success and "OK" in resp:
        try:
            lines = resp.split("\n")
            # Filter lines that actually contain a row id
            c = sum(1 for line in lines if "data_" in line)
            return c
        except:
            pass
    return -1

counts = {}
for port in [8081, 8082, 8083]:
    counts[port] = get_count(port)

print(f"Row counts: {counts}")

for p in nodes.values():
    os.killpg(os.getpgid(p.pid), signal.SIGKILL)

if len(set(counts.values())) == 1 and list(counts.values())[0] > 0:
    print("✅ CHAOS TEST PASSED! All nodes have consistent state.")
    sys.exit(0)
else:
    print("❌ CHAOS TEST FAILED! Inconsistent state.")
    sys.exit(1)
