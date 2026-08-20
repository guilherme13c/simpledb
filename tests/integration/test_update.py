import socket
import unittest
import os
import shutil
import subprocess
import time

class TestUpdate(unittest.TestCase):
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

    def test_update(self):
        client = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        client.connect(("127.0.0.1", 8080))
        
        commands = [
            "CREATE TABLE users (id int, name varchar, age int);",
            "INSERT INTO users VALUES (1, 'Alice', 30);",
            "INSERT INTO users VALUES (2, 'Bob', 25);",
            "INSERT INTO users VALUES (3, 'Charlie', 35);",
            "SELECT * FROM users;",
            "UPDATE users SET age = 31 WHERE id = 1;",
            "SELECT * FROM users WHERE id = 1;",
            "UPDATE users SET name = 'Bobby' WHERE age = 25;",
            "SELECT * FROM users WHERE age = 25;",
            "ALTER TABLE users ADD COLUMN active bool;",
            "ALTER TABLE users RENAME COLUMN age TO years;",
            "SELECT * FROM users WHERE active = false;",
        ]

        for cmd in commands:
            print(f"Sending: {cmd}")
            client.sendall(cmd.encode() + b"\n")
            response = client.recv(4096).decode()
            print(f"Response:\n{response}")

        client.close()

if __name__ == "__main__":
    unittest.main()
