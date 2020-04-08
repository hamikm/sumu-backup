from app import db
import json
from datetime import datetime

SHA256_LEN = 64

class MediaMetadata(db.Model):
    '''Define table of image metadata rows'''

    id = db.Column(db.String(36), primary_key=True)  # e.g. 96f23eaf-893a-4774-b38f-132e5d73daa8
    user = db.Column(db.String(20))  # e.g. hamik
    creationTimestamp = db.Column(db.Integer)  # time since epoch in seconds
    locationLatitude = db.Column(db.Float, nullable=True)  # e.g. 33.546
    locationLongitude = db.Column(db.Float, nullable=True)  # e.g. -118.335
    isFavorite = db.Column(db.Boolean)  # based on selection in iOS photos app
    absoluteFilename = db.Column(db.String(256))
    isVideo = db.Column(db.Boolean)

    def __repr__(self):
        return str(self.toDict())

    def toDict(self):
        return {
            'id': self.id,
            'user': self.user,
            'timestamp': self.creationTimestamp,
            'location': {
                'latitude': self.locationLatitude,
                'longitude': self.locationLongitude
            },
            'isFavorite': self.isFavorite,
            'absoluteFilename': self.absoluteFilename,
            'isVideo': self.isVideo
        }

    @classmethod
    def fromDict(cls, rowDict):
        return MediaMetadata(
            id=rowDict.get('id'),
            user=rowDict.get('user'),
            creationTimestamp=rowDict.get('creationTimestamp'),
            locationLatitude=rowDict.get('locationLatitude'),
            locationLongitude=rowDict.get('locationLongitude'),
            isFavorite=rowDict.get('isFavorite'),
            absoluteFilename=rowDict.get('absoluteFilename'),
            isVideo=rowDict.get('isVideo')
        )

    @classmethod
    def validate(cls, rowJson):
        if rowJson is None or type(rowJson) != dict:
            return False
        id = rowJson.get('id')
        user = rowJson.get('user')
        timestamp = rowJson.get('creationTimestamp')
        isFavorite = rowJson.get('isFavorite')
        locationX = rowJson.get('location') and rowJson.get('location').get('x')
        locationY = rowJson.get('location') and rowJson.get('location').get('y')        
        absoluteFilename = rowJson.get('absoluteFilename')
        isVideo = rowJson.get('isVideo')
        return (id is not None and type(id) == str
            and user is not None and type(user) == str
            and timestamp is not None and type(timestamp) == int
            and isFavorite is not None and type(isFavorite) == bool
            and (type(locationX) == float if locationX is not None else True)
            and (type(locationY) == float if locationY is not None else True)
            and absoluteFilename is not None and type(absoluteFilename) == str
            and isVideo is not None and type(isVideo) == bool
        )
