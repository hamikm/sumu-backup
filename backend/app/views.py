from app import app, models, db
from flask import request, jsonify
import base64
import uuid
import pathlib
import os

PW = 'beeblesissuchameerkat'
ENV = 'dev'
ROOT_DIR_DEV = '.'
ROOT_DIR_PROD = '/opt/plexmedia'
IMG_EXTENSION = 'png'
VIDEO_EXTENSION = 'mp4'
FILENAME_FORMAT = '{timestamp}_{uuid}.{extension}'
USER_DIRECTORY = '{root}/{user}'
DIRECTORY_TO_WRITE_FILES = '{userdir}/{album}'
ABS_FILENAME = '{dir}/{filename}'
FAVORITES_DIR_NAME = 'favorites'
DEFAULT_ALBUM = 'default'

def makeError(statusCode, msg=''):
    ret = jsonify({
        'status': statusCode,
        'message': msg
    })
    ret.status_code = statusCode
    return ret

@app.route('/health')
def health():
    password = request.args.get('p')
    if password != PW:
        return makeError(500, 'pwnd')
    return jsonify('ok')

@app.route('/timestamps', methods=['GET'])
def getTimestamps():
    '''Return dict with timestamps mapped to true if exactly 1 row has it, false if > 1 row'''
    password = request.args.get('p')
    if password != PW:
        return makeError(500, 'pwnd')

    user = request.args.get('u')
    ret = {}
    for row in models.MediaMetadata.query.all():
        if user != row.user:
            continue
        timestamp = row.creationTimestamp
        if ret.get(timestamp) is None:
            ret[timestamp] = True
        else:
            ret[timestamp] = False
    return jsonify(ret)

@app.route('/save', methods=['POST'])
def uploadImage():
    '''Receive image or video, store it in user plex directory'''
    content = request.get_json(silent=True)

    albumName = content.get('a')
    password = content.get('p')
    mediaData = content.get('i')
    oldId = content.get('d')

    if albumName is None:
        albumName = DEFAULT_ALBUM
    albumName = '_'.join(albumName.strip().split())

    if password != PW:
        return makeError(500, 'pwnd')

    # map from wire model
    rowDict = {
        'id': str(uuid.uuid4()) if oldId is None or len(oldId) == 0 else oldId,
        'user': content.get('u'),
        'creationTimestamp': content.get('t'),
        'locationLatitude': content.get('lat'),
        'locationLongitude': content.get('long'),
        'isFavorite': content.get('f'),
        'isVideo': content.get('v')
    }
    relativeFilename = FILENAME_FORMAT.format(
        timestamp=rowDict.get('creationTimestamp'),
        uuid=rowDict.get('id'),
        extension=(IMG_EXTENSION if not rowDict['isVideo'] else VIDEO_EXTENSION)
    )
    userDirectory = USER_DIRECTORY.format(
        root=ROOT_DIR_DEV if ENV == 'dev' else ROOT_DIR_PROD,
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
    if (models.MediaMetadata.validate(rowDict)):
        try:
            # make album directory if it doesn't exist yet
            if not pathlib.Path(directory).is_dir():
                os.mkdir(directory)
            if not pathlib.Path(favoritesDirectory).is_dir():
                os.mkdir(favoritesDirectory)

            # write image to favorites directory if it's a  favorite
            if rowDict.get('isFavorite'):
                with open(absFavoritePath, "ab") as fh:
                    fh.write(base64.b64decode(mediaData))

            # write it to its own album and put a metadata row in the DB
            with open(absPath, "ab") as fh:
                fh.write(base64.b64decode(mediaData))
                if oldId is None or len(oldId) == 0:  # create row only if hasn't been created
                    row = models.MediaMetadata.fromDict(rowDict)
                    db.session.add(row)
                    db.session.commit()
                ret = {'d': rowDict['id']}
                return jsonify(ret)
        except Exception as err:
            print (err)
            return makeError(500, str(err))
    else:
        return makeError(500)

    return jsonify('success')
