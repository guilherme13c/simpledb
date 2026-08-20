import socket
import unittest
import os
import shutil
import subprocess
import time

def send_query(sock, query):
    sock.sendall(query.encode('utf-8'))
    response = sock.recv(4096).decode('utf-8')
    return response

class TestCTE(unittest.TestCase):
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
                with socket.create_connection(("127.0.0.1", 8080), timeout=1):
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

    def test_cte_basic(self):
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.connect(('127.0.0.1', 8080))
        
        send_query(sock, "CREATE TABLE cte_test (id INT, score INT);")
        send_query(sock, "INSERT INTO cte_test VALUES (1, 100);")
        send_query(sock, "INSERT INTO cte_test VALUES (2, 200);")
        send_query(sock, "INSERT INTO cte_test VALUES (3, 300);")
        
        q = "WITH my_cte AS (SELECT * FROM cte_test WHERE score > 150) SELECT * FROM my_cte;"
        r = send_query(sock, q)
        lines = r.strip().split('\n')
        
        self.assertEqual(len(lines), 3) # 2 rows + OK
        self.assertIn('2 | 200', lines[0])
        self.assertIn('3 | 300', lines[1])

        sock.close()

if __name__ == "__main__":
    unittest.main()
