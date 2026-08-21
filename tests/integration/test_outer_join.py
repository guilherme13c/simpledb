import socket
import time
import unittest
import os
import shutil
import subprocess

def send_query(sock, query):
    sock.sendall((query + '\n').encode('utf-8'))
    response = sock.recv(4096).decode('utf-8')
    return response

class TestOuterJoin(unittest.TestCase):
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

    def test_left_join(self):
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.connect(('127.0.0.1', 8080))
        
        queries = [
            "CREATE TABLE users_oj (id INT, name VARCHAR);",
            "CREATE TABLE orders_oj (id INT, user_id INT, total INT);",
            "INSERT INTO users_oj VALUES (1, 'alice');",
            "INSERT INTO users_oj VALUES (2, 'bob');",
            "INSERT INTO users_oj VALUES (3, 'charlie');",
            "INSERT INTO orders_oj VALUES (10, 1, 100);",
            "INSERT INTO orders_oj VALUES (11, 2, 200);",
            "INSERT INTO orders_oj VALUES (12, 1, 150);"
        ]
        
        for q in queries:
            send_query(sock, q)
            
        r = send_query(sock, "SELECT * FROM users_oj LEFT JOIN orders_oj ON id = user_id;")
        
        lines = r.strip().split('\n')
        # alice has 2 orders
        # bob has 1 order
        # charlie has 0 orders, should be padded with NULLs
        print(lines)
        self.assertEqual(len(lines), 5)
        
        charlie_line = [l for l in lines if 'charlie' in l][0]
        self.assertIn('NULL | NULL | NULL', charlie_line)

        sock.close()

if __name__ == "__main__":
    unittest.main()
