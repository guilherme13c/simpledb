import subprocess
import socket
import time
import os
import shutil
import unittest

DB_PORT = 8080
HOST = "127.0.0.1"

class TestBufferPoolSpill(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if os.path.exists("data"):
            shutil.rmtree("data")
        os.makedirs("data", exist_ok=True)
        
        cls.server_proc = subprocess.Popen(
            ["./zig-out/bin/simpledb"],
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
        print("Tearing down server...", flush=True)
        cls.server_proc.terminate()
        try:
            print("Waiting for server to exit...", flush=True)
            cls.server_proc.wait(timeout=3)
            print("Server exited normally", flush=True)
        except subprocess.TimeoutExpired:
            print("Server did not exit, killing...", flush=True)
            cls.server_proc.kill()
            print("Server killed", flush=True)

    def send_query(self, query: str, timeout: float = 60.0) -> str:
        with socket.create_connection((HOST, DB_PORT)) as s:
            s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            s.settimeout(timeout)
            s.sendall(query.encode('utf-8') + b"\n")
            return s.recv(40960).decode('utf-8')

    def test_01_buffer_pool_spill(self):
        print("Starting test_01", flush=True)
        resp = self.send_query("CREATE TABLE spill_test (id INT, payload VARCHAR);")
        print("Created table", flush=True)
        self.assertIn("OK", resp)
        
        payload = "x" * 800
        
        # Open a single persistent connection for the inserts to speed them up
        with socket.create_connection((HOST, DB_PORT)) as s:
            s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            print("Opened connection for inserts", flush=True)
            s.settimeout(180.0)
            
            s.sendall(b"BEGIN;\n")
            print("Sent BEGIN", flush=True)
            resp = s.recv(4096)
            print(f"Recv BEGIN resp: {resp}", flush=True)
            self.assertIn(b"OK", resp)
            
            for i in range(5000):
                query = f"INSERT INTO spill_test VALUES ({i}, '{payload}');\n"
                s.sendall(query.encode('utf-8'))
                
                # Receive response to prevent server buffer overflow issues with partial lines
                resp = s.recv(4096)
                if b"ERR" in resp:
                    self.fail(f"Insert failed at row {i}: {resp}")
                if i % 1000 == 0:
                    print(f"Inserted {i} rows", flush=True)
                    
            s.sendall(b"COMMIT;\n")
            resp = s.recv(4096)
            self.assertIn(b"OK", resp)
            
        # At this point, the buffer manager MUST have spilled many pages to disk.
        # Verify that we can query data back without corruption (fetching pages back).
        
        # 1. Query the first row (likely evicted)
        resp = self.send_query("SELECT id FROM spill_test WHERE id = 0;")
        self.assertIn("0", resp)
        
        # 2. Query the last row
        resp = self.send_query("SELECT id FROM spill_test WHERE id = 4999;")
        self.assertIn("4999", resp)
        
        # 3. Perform a full table scan to ensure no page is corrupted
        resp = self.send_query("SELECT COUNT(id) FROM spill_test;")
        self.assertIn("5000", resp)

if __name__ == '__main__':
    unittest.main()
