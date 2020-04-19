# Sumu Backup
Back up photos and videos to your own server instead of iCloud!

![alt text](ios/imgs/appdemo.gif)

## What?
A minimalist iOS app and Flask web server. The app uploads all photos, videos, live photos, etc. from the phone and its iCloud account to the web server, which stuffs metadata into a database and stores the assets on disk. Throw in a media server like Plex to view your media from your laptop, TV, or phone.

## Usage
Run the web server in `backend` on your server, build this app onto your phone with XCode, and tap Upload Photos or Upload Videos to start. It is safe to kill the app and open it again later; it will pick up where it left off.

## The iOS App
A simple Swift app that uploads photos from disk and iCloud to a user-specified server running the web server in `backend`.

#### Building the app
Download Xcode and open this project in it. If you haven't made an iOS app before, you'll have to do some configuration. This [Apple tutorial](https://developer.apple.com/library/archive/referencelibrary/GettingStarted/DevelopiOSAppsSwift/) is a good place to start. Change `SERVER` in `Constants.swift` to point at your backup server; if your server is on the same LAN, you can just use its human-readable local DNS name. You'll also need to whitelist your server in App Transport Security Settings in `Info.plist`.

If the app and your server are all on the same WPA-protected network, the ghetto security in this repo might be sufficient — it certainly is for me. Otherwise, upgrade to https and don't store the password in plain text on the frontend or backend :-)

#### Image and video formats
Live photos are uploaded twice: once as an image, once as a short video. Images that are present on disk as formats other than `HEIC` are uploaded without conversion — `HEIC` images are first converted to `JPG`. Assets are chunked and sent to the web server with a multipart upload.

#### Deduping
We use user name and image creation timestamps to dedupe assets. When you tap an upload button, we retrieve all timestamps from the backend and use them to determine if an asset should be uploaded or not. If there's a creation timestamp collision between local assets — e.g., if WhatsApp saves a bunch of stuff to disk at exactly the same time — we hash them with SHA256, compare them to make sure they're not dupes, then spread their timestamps before uploading.

## The Backend
The backend puts files uploaded by the app from `ios` into `<base>/<user>/<album>/<timestamp_uuid.extn>`. Metadata like `isFavorite` and lat/long are stored in a SQLite database, `app.db`.

#### Starting the web server
You need `python3` and `pip3`. You might want Plex too!

1. `$ cd backend`
2. `$ python3 -m venv env` — create virtual environment
3. `$ . env/bin/activate` — turn it on
4. `$ (env) pip3 install -r requirements.txt` — install requirements in virtual environment
5. `$ (env) python3 serve.py` — start web server
6. Set up a cronjob that starts the web server if it isn't up. This is necessary because processes can spontaneously die for various reasons. Set an environment variable called `EDITOR` to whatever your favorite editor is. E.g., put `export EDITOR=emacs` at the bottom of `~/.bashrc` then source it. Run `crontab -e` to enter a new cronjob. E.g., `*/1 * * * * <path prefix>/sumu-backup/backend/start_sumu_backup.sh` will do a health check every minute and start the server if necessary. Alternatively, deploy this with Docker like a real person :-)

#### To search the database
1. `$ cd backend`
2. `$ . env/bin/activate`
3. `$ (env) python3`
4. `>>> from app import models`
5. `>>> models.MediaMetadata.query.all()`
6. `>>> models.MediaMetadata.query.filter_by(isFavorite=True)`

#### Album details
The frontend might decide to put images and videos in the same album directory. In fact, if an album name isn't given for a certain image or video, it defaults to the year and month in which it was taken, like `YY-MM`. That means that images and videos will often be mixed together. Live photos are uploaded as an image and a short video, and they're both stored in the same album.

Favorites are _copied_ instead of soft-linked to a special `favorites` album. Plex can't handle soft links; as of early 2020, its browser will show link targets but not sources. The expected behavior, of course, is showing both.
