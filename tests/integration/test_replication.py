import socket
import subprocess
import time
import unittest
import os

class TestReplication(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Clear data
        os.system("rm -f data/simple_8080.db data/simpledb_8080.wal data/simple_8081.db data/simpledb_8081.wal")
        
        # Start Leader
        cls.leader = subprocess.Popen(["./zig-out/bin/simpledb", "--port", "8080"])
        time.sleep(1) # wait for leader to start
        
        # Start Replica
        cls.replica = subprocess.Popen(["./zig-out/bin/simpledb", "--port", "8081", "--replica-of", "127.0.0.1:8080"])
        time.sleep(1) # wait for replica to start and connect

    @classmethod
    def tearDownClass(cls):
        cls.leader.terminate()
        cls.replica.terminate()
        cls.leader.wait()
        cls.replica.wait()

    def query(self, port, sql):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.connect(("127.0.0.1", port))
            s.sendall((sql + "\n").encode())
            data = s.recv(4096)
            return data.decode().strip()

    def test_replication_flow(self):
        # Write to leader
        res = self.query(8080, "CREATE TABLE users (id INT, name VARCHAR);")
        self.assertIn("OK", res)
        
        res = self.query(8080, "INSERT INTO users VALUES (1, 'Alice');")
        self.assertIn("OK", res)
        
        res = self.query(8080, "INSERT INTO users VALUES (2, 'Bob');")
        self.assertIn("OK", res)
        
        # Wait for replication to sync
        time.sleep(1)
        
        # Read from replica
        res = self.query(8081, "SELECT * FROM users;")
        self.assertIn("Alice", res)
        self.assertIn("Bob", res)
        self.assertNotIn("Error", res)

        # Write to replica should fail
        res = self.query(8081, "INSERT INTO users VALUES (3, 'Charlie');")
        self.assertIn("ERR", res)

if __name__ == "__main__":
    unittest.main()
