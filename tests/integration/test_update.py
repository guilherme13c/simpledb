import socket
import time
import subprocess

def run_test():
    server_process = subprocess.Popen(["zig", "build", "run"])

    try:
        client = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        for i in range(15):
            try:
                client.connect(("127.0.0.1", 8080))
                break
            except ConnectionRefusedError:
                time.sleep(1)
        else:
            raise Exception("Failed to connect to server")

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

    finally:
        server_process.terminate()
        server_process.wait()

if __name__ == "__main__":
    run_test()
