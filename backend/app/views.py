from app import app, models, db
from flask import request, jsonify
import base64
import uuid
import pathlib
import os
import shutil

PW = 'beeblesissuchameerkat'
ENV = os.environ.get('SUMU_BACKUP_ENV') or 'prod'
ROOT_DIR_DEV = '.'
ROOT_DIR_PROD = '/opt/plexmedia'
FILENAME_FORMAT = '{timestamp}_{uuid}.{extension}'
USER_DIRECTORY = '{root}/{user}'
DIRECTORY_TO_WRITE_FILES = '{userdir}/{album}'
FILE_PARTS_DIR='./tmp'
FILE_PART_NAME = '{dir}/{tmpUuid}_{chunkNum}'
ABS_FILENAME = '{dir}/{filename}'
FAVORITES_DIR_NAME = 'favorites'
DEFAULT_ALBUM = 'default'
UUID_LEN = 36

def makeError(statusCode, msg=''):
    ret = jsonify({
        'status': statusCode,
        'message': msg
    })
    ret.status_code = statusCode
    return ret

@app.route('/health')
def health():
    if request.args.get('p') != PW:
        return makeError(500, 'pwnd')
    return jsonify('ok')

def argsTimestamps(params):
    if params.get('p') != PW:
        raise Exception('pwnd')

    user = params.get('u')
    if type(user) is not str or len(user) == 0:
        errMsg = 'user needs to be a nonempty string!'
        raise Exception(errMsg)

    return user

def mapTimesSeenToBool(timesSeenIsLivePhoto):
    '''There are 3 outcomes: upload, not upload, crash. they corresond to None, True, False.

    If timesSeen is None, frontend should upload. If it's 1, frontend should NOT upload, NOT crash.
    If it's 2 but they're for the photo and video parts of a live photo, frontend should also
    neither upload nor crash. If it's 2 but not for live photo, it should crash. If 3 or greater,
    it should crash. Crashing is so I'm forced to investigate what happened on the backend :-)
    '''
    if timesSeenIsLivePhoto is None:
        return None

    timesSeen, isLivePhoto = timesSeenIsLivePhoto
    if timesSeen == 1 and isLivePhoto:  # doesn't make sense; there should be a paired photo or vid
        return False  # false means force a crash on the frontend
    elif timesSeen == 1:  # if saw photo or video once and it's not live, makes sense, just skip
        return True  # true means make frontend skip an upload
    elif timesSeen == 2 and isLivePhoto:  # makes sense, just skip
        return True
    else:  # if saw twice and is not live or saw 3 or more times, doesn't make sense. crash
        return False

@app.route('/timestamps', methods=['GET'])
def getTimestamps():
    '''Return dict with timestamps mapped to true if exactly 1 row has it, false if > 1 row'''
    try:
        user = argsTimestamps(request.args)
    except Exception as err:
        makeError(500, str(err))

    # record the number of times each timestamp occurs in the database
    timesSeen = {}
    for row in models.MediaMetadata.query.all():
        if user != row.user:
            continue
        timestamp = row.creationTimestamp
        isLivePhoto = row.isLivePhoto
        if timesSeen.get(timestamp) is None:
            timesSeen[timestamp] = [0, isLivePhoto]
        timesSeen[timestamp][0] += 1
        timesSeen[timestamp][1] = timesSeen[timestamp][1] and isLivePhoto

    ret = {k: mapTimesSeenToBool(v) for k, v in timesSeen.items()}
    return jsonify(ret)

def getChunkFilename(tmpUuid, chunkNum):
    return FILE_PART_NAME.format(dir=FILE_PARTS_DIR, tmpUuid=tmpUuid, chunkNum=chunkNum)

def argsPart(body):
    if body.get('p') != PW:
        raise Exception('pwnd')

    chunkNum = body.get('o')
    if type(chunkNum) is not int or chunkNum < 0:
        errMsg = 'Need nonnegative chunk number for file part upload, got {}'.format(chunkNum)
        raise Exception(errMsg)

    tmpUuid = body.get('d')
    if type(tmpUuid) is not str or len(tmpUuid) != UUID_LEN:
        errMsg = 'Need temporary uuid'
        raise Exception(errMsg)

    partFilename = getChunkFilename(tmpUuid, chunkNum)
    return chunkNum, partFilename

@app.route('/part', methods=['POST'])
def uploadPart():
    '''Receive part of image or video'''
    body = request.get_json(silent=True)

    # process and validate json body
    try:
        chunkNum, partFilename = argsPart(body)
    except Exception as err:
        print (err)
        return makeError(500, str(err))

    try:
        # make tmp directory if it doesn't exist yet
        if not pathlib.Path(FILE_PARTS_DIR).is_dir():
            os.mkdir(FILE_PARTS_DIR)

        # write part to tmp directory
        with open(partFilename, 'wb') as fh:
            fh.write(base64.b64decode(body.get('i')))
    except Exception as err:
        print (err)
        return makeError(500, str(err))
    return jsonify('')

def getFilenames(rowDict, album, fileExtension):
    relativeFilename = FILENAME_FORMAT.format(
        timestamp=rowDict.get('creationTimestamp'),
        uuid=rowDict.get('id'),
        extension=fileExtension
    )
    userDirectory = USER_DIRECTORY.format(
        root=ROOT_DIR_PROD if ENV == 'prod' else ROOT_DIR_DEV,
        user=rowDict.get('user')
    )
    directory = DIRECTORY_TO_WRITE_FILES.format(
        userdir=userDirectory,
        album=album
    )
    faveDirectory = DIRECTORY_TO_WRITE_FILES.format(
        userdir=userDirectory,
        album=FAVORITES_DIR_NAME
    )
    absPath = ABS_FILENAME.format(
        dir=directory,
        filename=relativeFilename
    )
    absFavePath = ABS_FILENAME.format(
        dir=faveDirectory,
        filename=relativeFilename
    )
    return absPath, absFavePath, directory, faveDirectory

def argsSave(body):
    if body.get('p') != PW:
        raise Exception('pwnd')

    numParts = body.get('n')
    if type(numParts) is not int or numParts <= 0:
        errMsg = 'Need positive numParts, got {}'.format(numParts)
        raise Exception(errMsg)

    album = body.get('a')
    if type(album) is not str or len(album) == 0:
        errMsg = 'Need nonempty album name'
        raise Exception(errMsg)
    album = '_'.join(album.strip().split())

    tmpUuid = body.get('d')
    if type(tmpUuid) is not str or len(tmpUuid) != UUID_LEN:
        errMsg = 'Need temporary uuid'
        raise Exception(errMsg)

    fileExtension = body.get('x')
    if type(fileExtension) is not str or len(fileExtension) == 0:
        errMsg = 'Need nonempty file suffix'
        raise Exception(errMsg)

    # map from wire model
    rowDict = {
        'id': str(uuid.uuid4()),
        'user': body.get('u'),
        'creationTimestamp': body.get('t'),
        'locationLatitude': body.get('lat'),
        'locationLongitude': body.get('long'),
        'isFavorite': body.get('f'),
        'isVideo': body.get('v'),
        'isLivePhoto': body.get('l')
    }
    absPath, absFavePath, directory, faveDirectory = getFilenames(rowDict, album, fileExtension)
    rowDict['absoluteFilename'] = absPath

    # validate the metadata
    if (not models.MediaMetadata.validate(rowDict)):
        errMsg = 'Metadata validation failed: {}'.format(rowDict)
        raise Exception(errMsg)

    return numParts, album, tmpUuid, rowDict, absFavePath, directory, faveDirectory

@app.route('/save', methods=['POST'])
def combinePartsAndSave():
    '''When parts are received, concat them, store result in plex dir, and write metadata to DB'''
    body = request.get_json(silent=True)

    # process and validate json body
    try:
        numParts, album, tmpUuid, rowDict, absFavePath, directory, faveDirectory = argsSave(body)
    except Exception as err:
        print (err)
        return makeError(500, str(err))

    # check that all expected file parts exist
    filePartsArr = [getChunkFilename(tmpUuid, chunkNum) for chunkNum in range(1, numParts + 1)]
    filePartExists = [os.path.isfile(filename) for filename in filePartsArr]
    if not all(filePartExists):
        fileExistence = {file: exists for (file, exists) in zip(filePartsArr, filePartExists)}
        errMsg = 'Not all expected parts were there! {}'.format(fileExistence)
        print (errMsg)
        return makeError(500, errMsg)

    # combine file parts and store in user plex directory
    try:
        # make album directory if it doesn't exist yet
        if not pathlib.Path(directory).is_dir():
            os.mkdir(directory)
        if not pathlib.Path(faveDirectory).is_dir():
            os.mkdir(faveDirectory)

        # write combined file to favorites directory if it's a favorite
        if rowDict.get('isFavorite'):
            with open(absFavePath, 'wb') as wfd:
                for f in filePartsArr:
                    with open(f, 'rb') as fd:
                        shutil.copyfileobj(fd, wfd)

        # write it to its own album and put a metadata row in the DB
        with open(rowDict.get('absoluteFilename'), 'wb') as wfd:
            for f in filePartsArr:
                with open(f, 'rb') as fd:
                    shutil.copyfileobj(fd, wfd)
            row = models.MediaMetadata.fromDict(rowDict)
            db.session.add(row)
            db.session.commit()

        # remove temporary files
        for filename in filePartsArr:
            os.remove(filename)

    except Exception as err:
        print (err)
        return makeError(500, str(err))

    return jsonify('')
