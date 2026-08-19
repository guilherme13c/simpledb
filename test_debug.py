import socket

def send_query(sock, query):
    sock.sendall(query.encode('utf-8'))
    response = sock.recv(4096).decode('utf-8')
    return response

sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.connect(('127.0.0.1', 8080))
print(send_query(sock, "CREATE TABLE win_test (id INT, group_id INT, score INT);"))
print(send_query(sock, "INSERT INTO win_test VALUES (1, 1, 100);"))
print(send_query(sock, "INSERT INTO win_test VALUES (2, 1, 200);"))
print(send_query(sock, "INSERT INTO win_test VALUES (3, 2, 150);"))
print(send_query(sock, "INSERT INTO win_test VALUES (4, 2, 300);"))

q = "SELECT id, group_id, score, ROW_NUMBER() OVER(PARTITION BY group_id ORDER BY score DESC) FROM win_test;"
r = send_query(sock, q)
print(r)
print(r.strip().split('\n'))

sock.close()
