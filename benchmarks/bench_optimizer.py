import socket
import time
import sys

HOST = "127.0.0.1"
DB_PORT = 8080

def send(s, msg):
    s.sendall(msg.encode('utf-8') + b"\n")
    return s.recv(4096 * 1024).decode('utf-8').strip()

def setup_db(s):
    print("Creating tables...")
    send(s, "CREATE TABLE t_tiny (id INT);")
    send(s, "CREATE TABLE t_large (id INT);")
    send(s, "CREATE TABLE j_left (id_left INT, val VARCHAR);")
    send(s, "CREATE TABLE j_right (id_right INT, val VARCHAR);")
    
    # Create indexes so the CBO can choose to use them
    send(s, "CREATE INDEX t_tiny_idx ON t_tiny (id);")
    send(s, "CREATE INDEX t_large_idx ON t_large (id);")

    print("Inserting into t_tiny (3 rows)...")
    send(s, "BEGIN;")
    for i in range(3):
        send(s, f"INSERT INTO t_tiny VALUES ({i}, 'tiny');")
    send(s, "COMMIT;")

    print("Inserting into t_large (5000 rows)...")
    send(s, "BEGIN;")
    for i in range(5000):
        send(s, f"INSERT INTO t_large VALUES ({i}, 'large');")
    send(s, "COMMIT;")

    print("Inserting into join tables (2000 rows each)...")
    send(s, "BEGIN;")
    for i in range(2000):
        send(s, f"INSERT INTO j_left VALUES ({i}, 'left');")
        send(s, f"INSERT INTO j_right VALUES ({i}, 'right');")
    send(s, "COMMIT;")

def run_benchmarks(s):
    print("\n================== BENCHMARKS ==================")
    
    # 1. Point lookup on tiny table (CBO should fallback to SeqScan)
    # Even though there is an index, CBO detects tiny table and prefers seq scan cache locality.
    start = time.time()
    for i in range(100):
        send(s, "SELECT * FROM t_tiny WHERE id = 1;")
    tiny_time = time.time() - start
    print(f"1. Tiny Table (SeqScan chosen by CBO) - 100 queries: {tiny_time:.4f} seconds")

    # 2. Point lookup on large table (CBO should choose IndexScan)
    start = time.time()
    for i in range(100):
        send(s, "SELECT * FROM t_large WHERE id = 2500;")
    large_time = time.time() - start
    print(f"2. Large Table (IndexScan chosen by CBO) - 100 queries: {large_time:.4f} seconds")

    # 3. Join benchmark
    # 2000 x 2000 = 4,000,000 NLJ iterations vs ~22k SortMerge iterations
    start = time.time()
    res = send(s, "SELECT * FROM j_left JOIN j_right ON id_left = id_right;")
    join_time = time.time() - start
    
    # Just to verify it actually joined successfully
    row_count = len([x for x in res.split('\n') if 'left |' in x])
    print(f"3. 2000x2000 Join (SortMerge chosen by CBO) - {row_count} rows output: {join_time:.4f} seconds")
    if row_count == 0:
        print("Join output:", res[:200]) # print first 200 chars
    print("================================================\n")

if __name__ == "__main__":
    print("Connecting to SimpleDB at 127.0.0.1:8080...")
    try:
        with socket.create_connection((HOST, DB_PORT)) as s:
            setup_db(s)
            run_benchmarks(s)
    except ConnectionRefusedError:
        print("Error: Could not connect to the database. Make sure the server is running!")
        sys.exit(1)
