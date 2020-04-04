from gevent.pywsgi import WSGIServer

from app import app, db

db.create_all()
http_server = WSGIServer(('', 9090), app)
http_server.serve_forever()
