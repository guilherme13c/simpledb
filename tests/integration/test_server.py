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
            ["zig", "build", "run"],
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
        # Teardown
        cls.server_proc.terminate()
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

if __name__ == '__main__':
    unittest.main()
