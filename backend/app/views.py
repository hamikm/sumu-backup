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
USER_DIRECTORY = '{root}/{user}'
DIRECTORY_TO_WRITE_FILES = '{userdir}/{album}'
ABS_FILENAME = '{dir}/{filename}'
FAVORITES_DIR_NAME = 'favorites'

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
    userDirectory = USER_DIRECTORY.format(
        root=ROOT_DIR,
        user=rowDict.get('user')
    )
    directory = DIRECTORY_TO_WRITE_FILES.format(
        userdir=userDirectory,
        album=albumName
    )
    favoritesDirectory = DIRECTORY_TO_WRITE_FILES.format(
        userdir=userDirectory,
        album=FAVORITES_DIR_NAME
    )
    absPath = ABS_FILENAME.format(
        dir=directory,
        filename=relativeFilename
    )
    absFavoritePath = ABS_FILENAME.format(
        dir=favoritesDirectory,
        filename=relativeFilename
    )
    rowDict['absoluteFilename'] = absPath

    # write image to disk and store metadata in database
    row = None
    if (models.ImageRow.validate(rowDict)):
        try:
            # make album directory if it doesn't exist yet
            if not pathlib.Path(directory).is_dir():
                os.mkdir(directory)
            if not pathlib.Path(favoritesDirectory).is_dir():
                os.mkdir(favoritesDirectory)

            # write image to favorites directory if it's a  favorite
            if rowDict.get('isFavorite'):
                with open(absFavoritePath, "wb") as fh:
                    fh.write(base64.b64decode(imageData))

            # write it to its own album and put a metadata row in the DB
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
