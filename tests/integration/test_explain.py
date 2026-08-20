import socket
import unittest
import os
import shutil
import subprocess
import time

HOST = "127.0.0.1"
DB_PORT = 8080

def send_query(s, msg):
    s.sendall(msg.encode('utf-8') + b"\n")
    return s.recv(4096 * 1024).decode('utf-8').strip()

class TestExplain(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if os.path.exists("data"):
            shutil.rmtree("data")
        os.makedirs("data", exist_ok=True)
        
        cls.server_proc = subprocess.Popen(
            ["./zig-out/bin/simpledb"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )
        
        connected = False
        for _ in range(30):
            try:
                with socket.create_connection((HOST, DB_PORT), timeout=1):
                    connected = True
                    break
            except (ConnectionRefusedError, socket.timeout):
                time.sleep(0.5)
                
        if not connected:
            cls.server_proc.kill()
            out, err = cls.server_proc.communicate()
            raise Exception(f"Server failed to start. Stdout: {out}\nStderr: {err}")

    @classmethod
    def tearDownClass(cls):
        cls.server_proc.kill()
        try:
            cls.server_proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            cls.server_proc.kill()

    def test_explain(self):
        with socket.create_connection((HOST, DB_PORT)) as s:
            # Setup
            send_query(s, "CREATE TABLE explain_users (id INT, age INT);")
            send_query(s, "CREATE INDEX idx_explain_users ON explain_users (id);")
            
            # 1. Simple SeqScan
            res = send_query(s, "EXPLAIN SELECT * FROM explain_users;")
            self.assertIn("SeqScan", res)

            # Insert rows so CBO chooses IndexScan (cost_idx=4 vs cost_seq=N)
            send_query(s, "BEGIN;")
            for i in range(5):
                send_query(s, f"INSERT INTO explain_users VALUES ({i}, {20+i});")
            send_query(s, "COMMIT;")

            # 2. IndexScan with condition
            res = send_query(s, "EXPLAIN SELECT * FROM explain_users WHERE id = 1;")
            self.assertIn("IndexScan", res)

            # 3. Join with limits and ordering
            send_query(s, "CREATE TABLE explain_roles (role_id INT);")
            res = send_query(s, "EXPLAIN SELECT * FROM explain_users JOIN explain_roles ON id = role_id ORDER BY age DESC LIMIT 10 OFFSET 5;")
            self.assertIn("Limit", res)
            self.assertIn("OrderBy", res)
            self.assertTrue("NestedLoopJoin" in res or "SortMergeJoin" in res)

if __name__ == "__main__":
    unittest.main()
