import subprocess
import socket
import time
import os
import shutil
import unittest

DB_PORT = 8080
HOST = "127.0.0.1"

class TestSimpleDBServer(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Clean up any existing db state so tests run fresh
        if os.path.exists("data"):
            shutil.rmtree("data")
        os.makedirs("data", exist_ok=True)
        
        # Start the simpledb server
        cls.server_proc = subprocess.Popen(
            ["./zig-out/bin/simpledb"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )
        
        # Wait for the server to be ready
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
        cls.server_proc.communicate()
        try:
            cls.server_proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            cls.server_proc.kill()

    def send_query(self, query: str) -> str:
        """Send a query to the DB and return the response."""
        with socket.create_connection((HOST, DB_PORT)) as s:
            s.sendall(query.encode('utf-8') + b"\n")
            response = s.recv(4096).decode('utf-8')
            return response

    def test_01_basic_table_and_insert(self):
        resp = self.send_query("CREATE TABLE users (id INT, name VARCHAR);")
        self.assertIn("OK", resp)
        
        resp = self.send_query("INSERT INTO users VALUES (1, 'Alice');")
        self.assertIn("OK", resp)
        
        resp = self.send_query("INSERT INTO users VALUES (2, 'Bob');")
        self.assertIn("OK", resp)

    def test_02_select(self):
        resp = self.send_query("SELECT * FROM users;")
        self.assertIn("Alice", resp)
        self.assertIn("Bob", resp)

    def test_03_invalid_syntax(self):
        resp = self.send_query("SEL ECT * FORM users;")
        self.assertIn("ERR PARSER", resp)

    def test_04_transactions(self):
        with socket.create_connection((HOST, DB_PORT)) as s:
            def send(msg: str) -> str:
                s.sendall(msg.encode('utf-8') + b"\n")
                return s.recv(4096).decode('utf-8').strip()
                
            self.assertEqual(send("BEGIN;"), "OK")
            self.assertEqual(send("INSERT INTO users VALUES (99, 'TxnTest');"), "OK")
            self.assertEqual(send("ROLLBACK;"), "OK")
            
            # Verify it was rolled back
            self.assertNotIn("TxnTest", send("SELECT * FROM users;"))
            
            # Test Commit
            self.assertEqual(send("BEGIN;"), "OK")
            self.assertEqual(send("INSERT INTO users VALUES (100, 'CommitTest');"), "OK")
            self.assertEqual(send("COMMIT;"), "OK")
            
            self.assertIn("CommitTest", send("SELECT * FROM users;"))

    def test_05_concurrency(self):
        # Open two connections
        s1 = socket.create_connection((HOST, DB_PORT))
        s2 = socket.create_connection((HOST, DB_PORT))
        
        # Start a transaction on s1
        s1.sendall(b"BEGIN;\n")
        self.assertIn(b"OK", s1.recv(1024))
        
        # Insert something
        s1.sendall(b"INSERT INTO users VALUES (42, 'Concurrent');\n")
        self.assertIn(b"OK", s1.recv(1024))
        
        # s2 tries to read (should not see the uncommitted data due to MVCC snapshot isolation)
        s2.sendall(b"SELECT * FROM users;\n")
        s2_resp = s2.recv(4096).decode('utf-8')
        self.assertNotIn("Concurrent", s2_resp)
        
        # s1 commits
        s1.sendall(b"COMMIT;\n")
        self.assertIn(b"OK", s1.recv(1024))
        
        # s2 reads again, it should see it now
        s2.sendall(b"SELECT * FROM users;\n")
        s2_resp2 = s2.recv(4096).decode('utf-8')
        self.assertIn("Concurrent", s2_resp2)
        
        s1.close()
        s2.close()

    def test_06_hash_join(self):
        resp = self.send_query("CREATE TABLE orders (order_id INT, user_id INT, item VARCHAR);")
        self.assertIn("OK", resp)
        
        # Insert enough rows to make HashJoin cheaper than NLJ (N=10)
        for i in range(10):
            self.send_query(f"INSERT INTO users VALUES ({10+i}, 'TestUser{i}');")
            self.send_query(f"INSERT INTO orders VALUES ({200+i}, {10+i}, 'Item{i}');")
        
        # Test EXPLAIN to verify HashJoin is used
        resp = self.send_query("EXPLAIN SELECT * FROM users JOIN orders ON id = user_id;")
        self.assertIn("HashJoin", resp)
        
        # Test actual execution
        resp = self.send_query("SELECT * FROM users JOIN orders ON id = user_id;")
        self.assertIn("Item5", resp)
        self.assertIn("Item9", resp)
        self.assertIn("TestUser5", resp)
        self.assertIn("TestUser9", resp)

    def test_07_hash_index(self):
        resp = self.send_query("CREATE TABLE hash_test (id INT, val INT);")
        self.assertIn("OK", resp)
        self.send_query("INSERT INTO hash_test VALUES (1, 100);")
        self.send_query("INSERT INTO hash_test VALUES (2, 200);")
        self.send_query("INSERT INTO hash_test VALUES (3, 300);")
        self.send_query("INSERT INTO hash_test VALUES (4, 400);")
        self.send_query("INSERT INTO hash_test VALUES (5, 500);")
        
        resp = self.send_query("CREATE INDEX idx_hash ON hash_test (val) USING HASH;")
        self.assertIn("OK", resp)
        
        # Explain should show IndexScan
        resp = self.send_query("EXPLAIN SELECT * FROM hash_test WHERE val = 200;")
        self.assertIn("IndexScan", resp)
        
        # Execution should work
        resp = self.send_query("SELECT * FROM hash_test WHERE val = 200;")
        self.assertIn("200", resp)
        self.assertNotIn("300", resp)

    def test_08_multiple_order_by(self):
        resp = self.send_query("CREATE TABLE order_test (id INT, cat INT);")
        self.send_query("INSERT INTO order_test VALUES (1, 10);")
        self.send_query("INSERT INTO order_test VALUES (2, 20);")
        self.send_query("INSERT INTO order_test VALUES (3, 10);")
        self.send_query("INSERT INTO order_test VALUES (4, 20);")
        
        resp = self.send_query("SELECT * FROM order_test ORDER BY cat DESC, id ASC;")
        self.assertIn("2", resp)
        self.assertIn("4", resp)
        self.assertIn("1", resp)
        self.assertIn("3", resp)
        
        # Test order
        idx_4 = resp.find("4")
        idx_1 = resp.find("1")
        self.assertTrue(idx_4 < idx_1)

if __name__ == '__main__':
    unittest.main()
