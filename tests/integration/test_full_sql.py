import subprocess
import socket
import time
import os
import shutil
import unittest

DB_PORT = 8080
HOST = "127.0.0.1"

class TestFullSQL(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Clean up any existing db state so tests run fresh
        if os.path.exists("data"):
            shutil.rmtree("data")
        os.makedirs("data", exist_ok=True)
        
        # Start the simpledb server
        cls.server_proc = subprocess.Popen(
            ["./zig-out/bin/simpledb"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )
        
        # Wait for the server to be ready
        connected = False
        for _ in range(30):
            try:
                with socket.create_connection((HOST, DB_PORT), timeout=1):
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
        # Teardown
        cls.server_proc.terminate()
        try:
            cls.server_proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            cls.server_proc.kill()

    def send_query(self, query: str) -> str:
        """Send a query to the DB and return the response."""
        with socket.create_connection((HOST, DB_PORT)) as s:
            s.sendall(query.encode('utf-8') + b"\n")
            response = s.recv(4096).decode('utf-8')
            return response

    def test_01_create_table_different_types(self):
        # Create table covering multiple implemented types
        query = """
        CREATE TABLE products (
            id INT,
            name VARCHAR,
            price FLOAT,
            in_stock BOOL,
            created_at TIMESTAMP
        );
        """
        resp = self.send_query(query.replace("\n", " ").strip())
        self.assertIn("OK", resp)

    def test_02_insert_and_select(self):
        self.send_query("INSERT INTO products VALUES (1, 'Laptop', 999.99, true, 1690000000);")
        self.send_query("INSERT INTO products VALUES (2, 'Mouse', 25.50, true, 1690000010);")
        self.send_query("INSERT INTO products VALUES (3, 'Keyboard', 45.00, false, 1690000020);")
        self.send_query("INSERT INTO products VALUES (4, 'Monitor', 150.75, true, 1690000030);")
        
        resp = self.send_query("SELECT * FROM products;")
        self.assertIn("Laptop", resp)
        self.assertIn("Mouse", resp)
        self.assertIn("999.99", resp)
        self.assertIn("true", resp)

    def test_03_comparisons_and_where(self):
        # Equals
        resp = self.send_query("SELECT * FROM products WHERE id = 1;")
        self.assertIn("Laptop", resp)
        self.assertNotIn("Mouse", resp)
        
        # Greater Than
        resp = self.send_query("SELECT * FROM products WHERE price > 50.0;")
        self.assertIn("Laptop", resp)
        self.assertIn("Monitor", resp)
        self.assertNotIn("Mouse", resp)
        self.assertNotIn("Keyboard", resp)
        
        # Less Than or Equals
        resp = self.send_query("SELECT * FROM products WHERE price <= 45.0;")
        self.assertIn("Mouse", resp)
        self.assertIn("Keyboard", resp)
        self.assertNotIn("Laptop", resp)

        # Not Equals
        resp = self.send_query("SELECT * FROM products WHERE in_stock != true;")
        self.assertIn("Keyboard", resp)
        self.assertNotIn("Laptop", resp)

        # AND condition
        resp = self.send_query("SELECT * FROM products WHERE price < 1000.0 AND in_stock = true;")
        self.assertIn("Mouse", resp)
        self.assertIn("Laptop", resp)
        self.assertNotIn("Keyboard", resp)

    def test_04_update(self):
        # Update price of the mouse
        resp = self.send_query("UPDATE products SET price = 20.00 WHERE name = 'Mouse';")
        self.assertIn("OK", resp)
        
        resp = self.send_query("SELECT * FROM products WHERE name = 'Mouse';")
        self.assertIn("20", resp)

    def test_05_delete(self):
        # Delete out-of-stock items
        resp = self.send_query("DELETE FROM products WHERE in_stock = false;")
        self.assertIn("OK", resp)
        
        resp = self.send_query("SELECT * FROM products;")
        self.assertNotIn("Keyboard", resp)
        self.assertIn("Laptop", resp)

    def test_06_order_by_and_limit(self):
        # Order by price ASC
        resp = self.send_query("SELECT * FROM products ORDER BY price ASC LIMIT 2;")
        # Should return Mouse (20.0) then Monitor (150.75)
        lines = [line for line in resp.strip().split("\n") if line and "OK" not in line]
        self.assertTrue(len(lines) >= 2)
        self.assertIn("Mouse", lines[0])
        self.assertIn("Monitor", lines[1])

        # Order by price DESC
        resp = self.send_query("SELECT * FROM products ORDER BY price DESC LIMIT 1 OFFSET 1;")
        # DESC: Laptop(999.99), Monitor(150.75), Mouse(20.0)
        # OFFSET 1, LIMIT 1 -> Monitor
        lines = [line for line in resp.strip().split("\n") if line and "OK" not in line]
        self.assertTrue(len(lines) >= 1)
        self.assertIn("Monitor", lines[0])
        self.assertNotIn("Laptop", lines[0])

    def test_07_aggregations(self):
        # COUNT
        resp = self.send_query("SELECT COUNT(id) FROM products;")
        self.assertIn("3", resp) # Laptop, Mouse, Monitor
        
        # SUM
        resp = self.send_query("SELECT SUM(price) FROM products;")
        # 999.99 + 20.0 + 150.75 = 1170.74
        self.assertIn("1170.74", resp)
        
        # MIN / MAX
        resp = self.send_query("SELECT MIN(price) FROM products;")
        self.assertIn("20", resp)
        
        resp = self.send_query("SELECT MAX(price) FROM products;")
        self.assertIn("999.99", resp)

    def test_08_group_by(self):
        self.send_query("INSERT INTO products VALUES (5, 'Cables', 10.0, true, 1690000040);")
        # Now products: Laptop(t), Mouse(t), Monitor(t), Cables(t)
        
        # Let's add a false one
        self.send_query("INSERT INTO products VALUES (6, 'Desk', 300.0, false, 1690000050);")
        
        resp = self.send_query("SELECT in_stock, COUNT(id) FROM products GROUP BY in_stock;")
        # Should have a group for true (4) and false (1)
        self.assertIn("true", resp)
        self.assertIn("4", resp)
        self.assertIn("false", resp)
        self.assertIn("1", resp)

    def test_09_join(self):
        self.send_query("CREATE TABLE categories (cat_id INT, cat_name VARCHAR);")
        self.send_query("INSERT INTO categories VALUES (1, 'Electronics');")
        self.send_query("INSERT INTO categories VALUES (2, 'Furniture');")
        
        self.send_query("CREATE TABLE item_cats (item_id INT, category_id INT);")
        self.send_query("INSERT INTO item_cats VALUES (1, 1);") # Laptop -> Electronics
        self.send_query("INSERT INTO item_cats VALUES (6, 2);") # Desk -> Furniture
        
        # Inner join
        resp = self.send_query("SELECT * FROM products JOIN item_cats ON id = item_id;")
        self.assertIn("Laptop", resp)
        self.assertIn("Desk", resp)
        self.assertNotIn("Mouse", resp) # Mouse wasn't mapped

    def test_10_transactions(self):
        with socket.create_connection((HOST, DB_PORT)) as s:
            def send(msg: str) -> str:
                s.sendall(msg.encode('utf-8') + b"\n")
                return s.recv(4096).decode('utf-8').strip()
                
            send("BEGIN;")
            send("INSERT INTO products VALUES (99, 'TxnTest', 0.0, false, 0);")
            send("ROLLBACK;")
            
            resp = send("SELECT * FROM products WHERE name = 'TxnTest';")
            self.assertNotIn("TxnTest", resp)
            
            send("BEGIN;")
            send("INSERT INTO products VALUES (100, 'CommitTest', 0.0, false, 0);")
            send("COMMIT;")
            
            resp = send("SELECT * FROM products WHERE name = 'CommitTest';")
            self.assertIn("CommitTest", resp)

if __name__ == '__main__':
    unittest.main()
