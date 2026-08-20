import subprocess
import socket
import time
import os
import shutil
import unittest

DB_PORT = 8080
HOST = "127.0.0.1"

class TestProperties(unittest.TestCase):
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

    def send_query(self, query: str) -> str:
        with socket.create_connection((HOST, DB_PORT)) as s:
            s.sendall(query.encode('utf-8') + b"\n")
            return s.recv(40960).decode('utf-8')

    def test_01_all_types(self):
        resp = self.send_query("CREATE TABLE all_types (a INT, b VARCHAR, c BOOL, d FLOAT, e TIMESTAMP, f JSON, h SIGNED_INT);")
        self.assertIn("OK", resp)
        resp = self.send_query("INSERT INTO all_types VALUES (1, 'str', true, 1.23, 123456, '{\"k\":\"v\"}', 42);")
        self.assertIn("OK", resp)
        resp = self.send_query("SELECT * FROM all_types;")
        self.assertIn("1", resp)
        self.assertIn("str", resp)
        self.assertIn("true", resp)
        self.assertIn("1.23", resp)
        self.assertIn("123456", resp)
        self.assertIn("{\"k\":\"v\"}", resp)
        self.assertIn("42", resp)

    def test_02_atomicity(self):
        self.send_query("CREATE TABLE atomicity_test (id INT);")
        with socket.create_connection((HOST, DB_PORT)) as s:
            def send(msg: str) -> str:
                s.sendall(msg.encode('utf-8') + b"\n")
                return s.recv(4096).decode('utf-8').strip()
                
            send("BEGIN;")
            send("INSERT INTO atomicity_test VALUES (1);")
            # syntax error
            send("INSERT INTO atomicity_test VALUES (bad);")
            send("ROLLBACK;")
        
        resp = self.send_query("SELECT * FROM atomicity_test;")
        self.assertNotIn("1", resp)

    def test_03_read_your_writes(self):
        self.send_query("CREATE TABLE ryw_test (id INT);")
        with socket.create_connection((HOST, DB_PORT)) as s:
            def send(msg: str) -> str:
                s.sendall(msg.encode('utf-8') + b"\n")
                return s.recv(4096).decode('utf-8').strip()
                
            send("BEGIN;")
            send("INSERT INTO ryw_test VALUES (99);")
            resp = send("SELECT * FROM ryw_test;")
            self.assertIn("99", resp)
            send("ROLLBACK;")
            
        resp = self.send_query("SELECT * FROM ryw_test;")
        self.assertNotIn("99", resp)

    def test_04_repeatable_read(self):
        self.send_query("CREATE TABLE rr_test (id INT, val INT);")
        self.send_query("INSERT INTO rr_test VALUES (1, 100);")
        
        s1 = socket.create_connection((HOST, DB_PORT))
        s2 = socket.create_connection((HOST, DB_PORT))
        
        def send(s, msg: str) -> str:
            s.sendall(msg.encode('utf-8') + b"\n")
            return s.recv(4096).decode('utf-8').strip()
            
        send(s1, "BEGIN;")
        resp1 = send(s1, "SELECT * FROM rr_test WHERE id = 1;")
        self.assertIn("100", resp1)
        
        send(s2, "BEGIN;")
        send(s2, "UPDATE rr_test SET val = 200 WHERE id = 1;")
        send(s2, "COMMIT;")
        
        resp2 = send(s1, "SELECT * FROM rr_test WHERE id = 1;")
        # Should still be 100 in s1's snapshot
        self.assertIn("100", resp2)
        self.assertNotIn("200", resp2)
        
        send(s1, "COMMIT;")
        s1.close()
        s2.close()
        
        resp3 = self.send_query("SELECT * FROM rr_test WHERE id = 1;")
        self.assertIn("200", resp3)

    def test_05_alter_table_drop(self):
        self.send_query("CREATE TABLE drop_col_test (id INT, val INT);")
        self.send_query("INSERT INTO drop_col_test VALUES (1, 100);")
        self.send_query("ALTER TABLE drop_col_test DROP COLUMN val;")
        resp = self.send_query("SELECT * FROM drop_col_test;")
        self.assertIn("1", resp)
        self.assertNotIn("100", resp)


    def test_07_concurrent_inserts(self):
        self.send_query("CREATE TABLE conc_insert (id INT, val INT);")
        
        def insert_worker(start_id, count):
            with socket.create_connection((HOST, DB_PORT)) as s:
                for i in range(start_id, start_id + count):
                    query = f"INSERT INTO conc_insert VALUES ({i}, {i*10});\n"
                    s.sendall(query.encode('utf-8'))
                    s.recv(1024)
                    
        import threading
        threads = []
        for i in range(5):
            t = threading.Thread(target=insert_worker, args=(i*100, 100))
            threads.append(t)
            t.start()
            
        for t in threads:
            t.join()
            
        resp = self.send_query("SELECT COUNT(id) FROM conc_insert;")
        self.assertIn("500", resp)

    def test_08_large_payload(self):
        self.send_query("CREATE TABLE large_text (id INT, txt VARCHAR);")
        large_str = "A" * 800
        self.send_query(f"INSERT INTO large_text VALUES (1, '{large_str}');")
        resp = self.send_query("SELECT * FROM large_text;")
        self.assertTrue(large_str in resp)

if __name__ == '__main__':
    unittest.main()
