import socket
import sys

HOST = "127.0.0.1"
DB_PORT = 8080

def send(s, msg):
    s.sendall(msg.encode('utf-8') + b"\n")
    return s.recv(4096 * 1024).decode('utf-8').strip()

def run_tests(s):
    # Setup
    send(s, "CREATE TABLE explain_users (id INT, age INT);")
    send(s, "CREATE INDEX idx_explain_users ON explain_users (id);")
    
    # 1. Simple SeqScan
    res = send(s, "EXPLAIN SELECT * FROM explain_users;")
    assert "SeqScan" in res, f"Expected SeqScan, got: {res}"

    # Insert rows so CBO chooses IndexScan (cost_idx=4 vs cost_seq=N)
    send(s, "BEGIN;")
    for i in range(5):
        send(s, f"INSERT INTO explain_users VALUES ({i}, {20+i});")
    send(s, "COMMIT;")

    # 2. IndexScan with condition
    res = send(s, "EXPLAIN SELECT * FROM explain_users WHERE id = 1;")
    assert "IndexScan" in res, f"Expected IndexScan, got: {res}"

    # 3. Join with limits and ordering
    send(s, "CREATE TABLE explain_roles (role_id INT);")
    res = send(s, "EXPLAIN SELECT * FROM explain_users JOIN explain_roles ON id = role_id ORDER BY age DESC LIMIT 10 OFFSET 5;")
    assert "Limit" in res, f"Expected Limit, got: {res}"
    assert "OrderBy" in res, f"Expected OrderBy, got: {res}"
    assert "NestedLoopJoin" in res or "SortMergeJoin" in res, f"Expected Join, got: {res}"

    print("All EXPLAIN tests passed!")

if __name__ == "__main__":
    try:
        with socket.create_connection((HOST, DB_PORT)) as s:
            run_tests(s)
    except ConnectionRefusedError:
        print("Server not running.")
        sys.exit(1)
