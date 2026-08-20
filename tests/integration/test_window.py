import socket
import unittest
import time
import os
import shutil
import subprocess

def send_query(sock, query):
    sock.sendall(query.encode('utf-8'))
    response = sock.recv(4096).decode('utf-8')
    return response

class TestWindow(unittest.TestCase):
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

    def test_window_basic(self):
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        
        # Add retries for connection
        connected = False
        for _ in range(5):
            try:
                sock.connect(('127.0.0.1', 8080))
                connected = True
                break
            except ConnectionRefusedError:
                time.sleep(1)
        self.assertTrue(connected, "Failed to connect to SimpleDB")

        send_query(sock, "CREATE TABLE win_test_final (id INT, group_id INT, score INT);")
        send_query(sock, "INSERT INTO win_test_final VALUES (1, 1, 100);")
        send_query(sock, "INSERT INTO win_test_final VALUES (2, 1, 200);")
        send_query(sock, "INSERT INTO win_test_final VALUES (3, 2, 150);")
        send_query(sock, "INSERT INTO win_test_final VALUES (4, 2, 300);")
        
        # Test ROW_NUMBER() OVER(PARTITION BY group_id ORDER BY score DESC)
        q = "SELECT id, group_id, score, ROW_NUMBER() OVER(PARTITION BY group_id ORDER BY score DESC) FROM win_test_final;"
        r = send_query(sock, q)
        lines = r.strip().split('\n')
        
        self.assertEqual(len(lines), 5) # 4 rows + OK
        
        self.assertIn('2 | 1 | 200 | 1', lines[0])
        self.assertIn('1 | 1 | 100 | 2', lines[1])
        self.assertIn('4 | 2 | 300 | 1', lines[2])
        self.assertIn('3 | 2 | 150 | 2', lines[3])

        sock.close()

if __name__ == "__main__":
    unittest.main()
