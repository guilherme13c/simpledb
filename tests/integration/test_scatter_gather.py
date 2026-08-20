import socket
import time
import subprocess
import os

def run_query(port, query, expect_ok=True):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.connect(('127.0.0.1', port))
    s.sendall((query + '\n').encode())
    
    resp = b""
    while True:
        chunk = s.recv(4096)
        if not chunk:
            break
        resp += chunk
        if b"OK\n" in resp or b"ERR" in resp:
            break
            
    s.close()
    
    resp_str = resp.decode().strip()
    if expect_ok and "ERR" in resp_str:
        print(f"[{port}] Query failed: {query} -> {resp_str}")
    return resp_str

print("Starting shards...")
shard0 = subprocess.Popen(["./zig-out/bin/simpledb", "--port", "8080", "--num-shards", "2", "--shard-id", "0"])
shard1 = subprocess.Popen(["./zig-out/bin/simpledb", "--port", "8081", "--num-shards", "2", "--shard-id", "1", "--seed", "127.0.0.1:8080"])
time.sleep(2)

try:
    print("Creating table...")
    run_query(8080, "CREATE TABLE users (id int, name varchar)")
    run_query(8081, "CREATE TABLE users (id int, name varchar)")

    print("Inserting data...")
    # 10 is even (shard 0) if num_shards=2, 11 is odd (shard 1)
    run_query(8080, "INSERT INTO users VALUES (10, 'Alice')")
    run_query(8080, "INSERT INTO users VALUES (11, 'Bob')")
    
    print("Testing SELECT from Shard 0 (Scatter-Gather)...")
    res = run_query(8080, "SELECT * FROM users")
    print(f"Result:\n{res}")
    
    if "Alice" in res and "Bob" in res:
        print("SUCCESS! Scatter-Gather returned data from both shards!")
    else:
        print("FAILED: Missing data in response.")

finally:
    shard0.terminate()
    shard1.terminate()
    shard0.wait()
    shard1.wait()
    os.system("rm -f *.db *.wal")
