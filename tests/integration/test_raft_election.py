import socket
import subprocess
import time
import unittest
import os
import shutil

class TestRaftElection(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if os.path.exists("data"):
            shutil.rmtree("data")
        os.makedirs("data", exist_ok=True)
        os.system("killall -9 simpledb 2>/dev/null")
        time.sleep(0.5)

        cls.server_proc = subprocess.Popen(
            ["./zig-out/bin/simpledb", "--port", "8080"]
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
            raise Exception("Server failed to start.")

        # Wait for election to complete
        time.sleep(3)

    @classmethod
    def tearDownClass(cls):
        cls.server_proc.terminate()
        try:
            cls.server_proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            cls.server_proc.kill()
        os.system("killall -9 simpledb 2>/dev/null")

    def send_query(self, port, query):
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.connect(('127.0.0.1', port))
        sock.sendall((query + '\n').encode('utf-8'))
        response = sock.recv(4096).decode('utf-8')
        sock.close()
        return response

    def test_leader_writes(self):
        # The single node should have elected itself leader and accept writes
        r1 = self.send_query(8080, "CREATE TABLE raft_test (id INT);")
        self.assertIn("OK", r1)

        r2 = self.send_query(8080, "INSERT INTO raft_test VALUES (42);")
        self.assertIn("OK", r2)

        r3 = self.send_query(8080, "SELECT * FROM raft_test;")
        self.assertIn("42", r3)

if __name__ == "__main__":
    unittest.main()
