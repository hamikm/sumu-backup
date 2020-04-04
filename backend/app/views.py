from app import app, models, db
from flask import request, jsonify
import base64
import uuid
import pathlib
import os

PW = 'beeblesissuchameerkat'
ROOT_DIR = '/Users/Mukelyan/sandbox/sumu-backup/backend'  # TODO update for server
EXTENSION = 'png'
FILENAME_FORMAT = '{timestamp}_{uuid}.{extension}'
DIRECTORY_TO_WRITE_FILES='{root}/{user}/{album}'
ABS_FILENAME = '{dir}/{filename}'

def makeError(statusCode, msg=''):
    ret = jsonify({
        'status': statusCode,
        'message': msg
    })
    ret.status_code = statusCode
    return ret


@app.route('/health')
def health():
    return jsonify('ok')


@app.route('/save', methods=['POST'])
def uploadImage():
    '''Receive image, store it in user plex directory'''
    content = request.get_json(silent=True)

    albumName = content.get('a')
    password = content.get('p')
    imageData = content.get('i')

    if password != PW:
        return makeError(500, 'pwnd')

    # map from wire model
    rowDict = {
        'id': str(uuid.uuid4()),
        'user': content.get('u'),
        'creationTimestamp': content.get('t'),
        'locationLatitude': content.get('lat'),
        'locationLongitude': content.get('long'),
        'isFavorite': content.get('f')
    }
    relativeFilename = FILENAME_FORMAT.format(
        timestamp=rowDict.get('creationTimestamp'),
        uuid=rowDict.get('id'),
        extension=EXTENSION
    )
    directory = DIRECTORY_TO_WRITE_FILES.format(
        root=ROOT_DIR,
        user=rowDict.get('user'),
        album=albumName,
    )
    absPath = ABS_FILENAME.format(
        dir=directory,
        filename=relativeFilename
    )
    rowDict['absoluteFilename'] = absPath

    # write image to disk and store metadata in database
    row = None
    if (models.ImageRow.validate(rowDict)):
        try:
            if not pathlib.Path(directory).is_dir():
                os.mkdir(directory)
            with open(absPath, "wb") as fh:
                fh.write(base64.b64decode(imageData))
                row = models.ImageRow.fromDict(rowDict)
                db.session.add(row)
                db.session.commit()
                ret = {'id': row.id}
                return jsonify(ret)
        except Exception as err:
            print (err)
            return makeError(500, str(err))
    else:
        return makeError(500)

    return jsonify('success')
