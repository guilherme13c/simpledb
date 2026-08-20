import subprocess
import socket
import time
import os
import shutil
import unittest
import threading

DB_PORT = 8080
HOST = "127.0.0.1"

class TestConcurrencyEdgeCases(unittest.TestCase):
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
            
        # Initialize test data
        cls.send_query_cls("CREATE TABLE items (id INT, value INT);")
        cls.send_query_cls("INSERT INTO items VALUES (1, 10);")
        cls.send_query_cls("INSERT INTO items VALUES (2, 20);")
        cls.send_query_cls("INSERT INTO items VALUES (3, 30);")

    @classmethod
    def tearDownClass(cls):
        # Teardown
        cls.server_proc.terminate()
        try:
            cls.server_proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            cls.server_proc.kill()

    @classmethod
    def send_query_cls(cls, query: str) -> str:
        with socket.create_connection((HOST, DB_PORT)) as s:
            s.sendall(query.encode('utf-8') + b"\n")
            return s.recv(4096).decode('utf-8')

    def send_query(self, query: str) -> str:
        """Send a query to the DB and return the response."""
        return self.send_query_cls(query)
        
    def test_01_deadlock(self):
        """
        Connection A updates row 1, then row 2.
        Connection B updates row 2, then row 1.
        Assert that the database resolves or safely aborts instead of hanging.
        """
        barrier = threading.Barrier(2)
        results = {}
        
        def thread_a():
            with socket.create_connection((HOST, DB_PORT)) as s:
                def send(msg: str) -> str:
                    s.sendall(msg.encode('utf-8') + b"\n")
                    return s.recv(4096).decode('utf-8').strip()
                try:
                    send("BEGIN;")
                    res1 = send("UPDATE items SET value = 11 WHERE id = 1;")
                    barrier.wait(timeout=5)
                    time.sleep(0.1) # small delay to ensure threads interleave
                    res2 = send("UPDATE items SET value = 21 WHERE id = 2;")
                    res3 = send("COMMIT;")
                    results['A'] = (res1, res2, res3)
                except Exception as e:
                    results['A'] = str(e)
                    
        def thread_b():
            with socket.create_connection((HOST, DB_PORT)) as s:
                def send(msg: str) -> str:
                    s.sendall(msg.encode('utf-8') + b"\n")
                    return s.recv(4096).decode('utf-8').strip()
                try:
                    send("BEGIN;")
                    res1 = send("UPDATE items SET value = 22 WHERE id = 2;")
                    barrier.wait(timeout=5)
                    time.sleep(0.1) # small delay to ensure threads interleave
                    res2 = send("UPDATE items SET value = 12 WHERE id = 1;")
                    res3 = send("COMMIT;")
                    results['B'] = (res1, res2, res3)
                except Exception as e:
                    results['B'] = str(e)
                    
        t1 = threading.Thread(target=thread_a)
        t2 = threading.Thread(target=thread_b)
        
        t1.start()
        t2.start()
        
        t1.join(timeout=10)
        t2.join(timeout=10)
        
        self.assertFalse(t1.is_alive(), "Thread A hung, possibly due to an unresolved deadlock.")
        self.assertFalse(t2.is_alive(), "Thread B hung, possibly due to an unresolved deadlock.")
        
        # Verify database is still responsive
        resp = self.send_query("SELECT * FROM items WHERE id = 1;")
        self.assertIsInstance(resp, str)
        self.assertIn("OK", resp)

    def test_02_lost_updates(self):
        """
        Test concurrent UPDATE statements on the same row.
        """
        def update_thread(thread_id):
            with socket.create_connection((HOST, DB_PORT)) as s:
                def send(msg: str) -> str:
                    s.sendall(msg.encode('utf-8') + b"\n")
                    return s.recv(4096).decode('utf-8').strip()
                try:
                    send("BEGIN;")
                    send(f"UPDATE items SET value = {thread_id} WHERE id = 3;")
                    send("COMMIT;")
                except Exception:
                    pass

        threads = []
        for i in range(100, 110):
            t = threading.Thread(target=update_thread, args=(i,))
            threads.append(t)
            
        for t in threads:
            t.start()
            
        for t in threads:
            t.join(timeout=10)
            self.assertFalse(t.is_alive(), f"Update thread {t.name} hung.")
            
        # Verify database is still responsive
        resp = self.send_query("SELECT * FROM items WHERE id = 3;")
        self.assertIsInstance(resp, str)
        self.assertIn("OK", resp)

if __name__ == '__main__':
    unittest.main()
