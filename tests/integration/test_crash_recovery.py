import subprocess
import socket
import time
import os
import shutil
import unittest

DB_PORT = 8080
HOST = "127.0.0.1"

class TestCrashRecovery(unittest.TestCase):
    def setUp(self):
        # Clean up any existing db state so tests run fresh
        if os.path.exists("data"):
            shutil.rmtree("data")
        os.makedirs("data", exist_ok=True)
        self.server_proc = None

    def tearDown(self):
        self.kill_server()

    def start_server(self):
        self.server_proc = subprocess.Popen(
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
            except (ConnectionRefusedError, socket.timeout, OSError):
                time.sleep(0.5)
                
        if not connected:
            self.kill_server()
            raise Exception("Server failed to start in time.")

    def kill_server(self):
        if self.server_proc is not None:
            self.server_proc.kill()
            self.server_proc.communicate()
            try:
                self.server_proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.server_proc.kill()
            self.server_proc = None

    def send_query(self, query: str) -> str:
        """Send a query to the DB and return the response."""
        with socket.create_connection((HOST, DB_PORT)) as s:
            s.sendall(query.encode('utf-8') + b"\n")
            response = s.recv(4096).decode('utf-8')
            return response

    def test_crash_recovery_uncommitted_txn(self):
        self.start_server()
        
        # Create a table
        resp = self.send_query("CREATE TABLE crash_test (id INT, val VARCHAR);")
        self.assertIn("OK", resp)
        
        # Begin a transaction and insert records without committing
        with socket.create_connection((HOST, DB_PORT)) as s:
            def send(msg: str) -> str:
                s.sendall(msg.encode('utf-8') + b"\n")
                return s.recv(4096).decode('utf-8').strip()
            
            self.assertEqual(send("BEGIN;"), "OK")
            self.assertEqual(send("INSERT INTO crash_test VALUES (1, 'Uncommitted1');"), "OK")
            self.assertEqual(send("INSERT INTO crash_test VALUES (2, 'Uncommitted2');"), "OK")
            self.assertEqual(send("INSERT INTO crash_test VALUES (3, 'Uncommitted3');"), "OK")
            
            # Violently kill the server while transaction is uncommitted
            self.kill_server()
            
        # Start the server again to trigger ARIES crash recovery (undo pass)
        self.start_server()
        
        # Query the table to assert that the uncommitted records are NOT present
        resp = self.send_query("SELECT * FROM crash_test;")
        self.assertNotIn("Uncommitted1", resp)
        self.assertNotIn("Uncommitted2", resp)
        self.assertNotIn("Uncommitted3", resp)

if __name__ == '__main__':
    unittest.main()
