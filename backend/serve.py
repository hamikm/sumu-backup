#!env/bin/python
from flask import Flask, request, jsonify, abort, make_response
from gevent.pywsgi import WSGIServer
import base64


app = Flask(__name__)


def makeError(statusCode, msg):
    ret = jsonify({
        'status': statusCode,
        'message': msg
    })
    ret.status_code = statusCode
    return ret


@app.route('/health')
def health():
    return 'ok'


@app.route('/image', methods=['POST'])
def uploadImage():
    '''Receive image, store it in user plex directory'''
    content = request.get_json(silent=True)
    user = content.get('d')
    albumName = content.get('a')
    password = content.get('l')
    imageData = content.get('i')

    if password != 'beeblesissuchameerkat':
        return makeError(500, "pwded")

    with open("test.png", "wb") as fh:
        fh.write(base64.b64decode(imageData))

    return "success"


http_server = WSGIServer(('', 9090), app)
http_server.serve_forever()
