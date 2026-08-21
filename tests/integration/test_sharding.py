import socket
import subprocess
import time
import unittest
import os
import shutil

class TestSharding(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if os.path.exists("data"):
            shutil.rmtree("data")
        os.makedirs("data", exist_ok=True)
        os.system("killall -9 simpledb 2>/dev/null")
        time.sleep(0.5)
        
        cls.shard0 = subprocess.Popen(
            ["./zig-out/bin/simpledb", "--port", "8080", "--num-shards", "2", "--shard-id", "0"]
        )
        time.sleep(1)
        
        cls.shard1 = subprocess.Popen(
            ["./zig-out/bin/simpledb", "--port", "8081", "--num-shards", "2", "--shard-id", "1", "--seed", "127.0.0.1:8080"]
        )
        
        for port in [8080, 8081]:
            connected = False
            for _ in range(30):
                try:
                    with socket.create_connection(("127.0.0.1", port), timeout=1):
                        connected = True
                        break
                except (ConnectionRefusedError, socket.timeout):
                    time.sleep(0.5)
            if not connected:
                cls.shard0.kill()
                cls.shard1.kill()
                raise Exception(f"Server on port {port} failed to start.")

        time.sleep(2) # wait for gossip sync

    @classmethod
    def tearDownClass(cls):
        cls.shard0.terminate()
        cls.shard1.terminate()
        try:
            cls.shard0.wait(timeout=3)
            cls.shard1.wait(timeout=3)
        except subprocess.TimeoutExpired:
            pass
        os.system("killall -9 simpledb 2>/dev/null")

    def send_query(self, port, query):
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.connect(('127.0.0.1', port))
        sock.sendall((query + '\n').encode('utf-8'))
        response = sock.recv(4096).decode('utf-8')
        sock.close()
        return response

    def test_sharding(self):
        # Create table on both shards
        r = self.send_query(8080, "CREATE TABLE shard_test (id INT, name VARCHAR);")
        self.assertIn("OK", r)
        r = self.send_query(8081, "CREATE TABLE shard_test (id INT, name VARCHAR);")
        self.assertIn("OK", r)

        # Insert rows, some should be forwarded
        r = self.send_query(8080, "INSERT INTO shard_test VALUES (10, 'A');")
        self.assertNotIn("ERR", r)
        r = self.send_query(8080, "INSERT INTO shard_test VALUES (11, 'B');")
        self.assertNotIn("ERR", r)

        # Query all, scatter-gather should return both
        r = self.send_query(8080, "SELECT * FROM shard_test;")
        self.assertNotIn("ERR", r)
        
        lines = r.strip().split('\n')
        self.assertEqual(len(lines), 3) # 2 rows + OK
        self.assertIn("A", r)
        self.assertIn("B", r)

if __name__ == "__main__":
    unittest.main()
