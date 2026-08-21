import socket
import subprocess
import time
import unittest
import os
import shutil

class TestReplicationConsistency(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if os.path.exists("data"):
            shutil.rmtree("data")
        os.makedirs("data", exist_ok=True)
        os.system("killall -9 simpledb 2>/dev/null")
        time.sleep(0.5)
        
        cls.leader = subprocess.Popen(
            ["./zig-out/bin/simpledb", "--port", "8080"]
        )
        time.sleep(1)
        
        cls.replica = subprocess.Popen(
            ["./zig-out/bin/simpledb", "--port", "8081", "--replica-of", "127.0.0.1:8080"]
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
                cls.leader.kill()
                cls.replica.kill()
                raise Exception(f"Server on port {port} failed to start.")

        time.sleep(2) # wait for sync

    @classmethod
    def tearDownClass(cls):
        cls.leader.terminate()
        cls.replica.terminate()
        try:
            cls.leader.wait(timeout=3)
            cls.replica.wait(timeout=3)
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

    def test_replication_consistency(self):
        # Write to leader
        r = self.send_query(8080, "CREATE TABLE repl_test (id INT, val VARCHAR);")
        self.assertIn("OK", r)

        r = self.send_query(8080, "INSERT INTO repl_test VALUES (1, 'one');")
        self.assertIn("OK", r)
        r = self.send_query(8080, "INSERT INTO repl_test VALUES (2, 'two');")
        self.assertIn("OK", r)

        # Wait for replication
        time.sleep(2)

        # Verify rows on replica
        r = self.send_query(8081, "SELECT * FROM repl_test;")
        self.assertIn("one", r)
        self.assertIn("two", r)
        self.assertNotIn("ERR", r)

        # Delete on leader
        r = self.send_query(8080, "DELETE FROM repl_test WHERE id = 1;")
        self.assertIn("OK", r)

        # Wait for replication
        time.sleep(2)

        # Verify deletion on replica
        r = self.send_query(8081, "SELECT * FROM repl_test;")
        self.assertNotIn("one", r)
        self.assertIn("two", r)

        # Write to replica should fail
        r = self.send_query(8081, "INSERT INTO repl_test VALUES (3, 'three');")
        self.assertIn("ERR", r)

if __name__ == "__main__":
    unittest.main()
