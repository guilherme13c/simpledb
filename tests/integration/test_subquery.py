import socket
import time
import unittest

def send_query(sock, query):
    sock.sendall(query.encode('utf-8'))
    response = sock.recv(4096).decode('utf-8')
    return response

class TestSubquery(unittest.TestCase):
    def test_scalar_subquery(self):
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.connect(('127.0.0.1', 8080))
        
        queries = [
            "CREATE TABLE sq_users (id INT, name VARCHAR, age INT);",
            "INSERT INTO sq_users VALUES (1, 'alice', 30);",
            "INSERT INTO sq_users VALUES (2, 'bob', 40);",
            "INSERT INTO sq_users VALUES (3, 'charlie', 50);"
        ]
        
        for q in queries:
            send_query(sock, q)
            
        r = send_query(sock, "SELECT * FROM sq_users WHERE age = (SELECT MAX(age) FROM sq_users);")
        
        lines = r.strip().split('\n')
        # We expect one data row for charlie, plus "OK"
        self.assertEqual(len(lines), 2)
        self.assertIn('3 | charlie | 50', lines[0])

        sock.close()

if __name__ == "__main__":
    unittest.main()
