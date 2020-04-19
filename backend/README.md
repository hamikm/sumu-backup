# Sumu Backup Backend
A tiny Flask web server that stores images and videos from a frontend on disk. It puts the files in a folder that my Plex media server is watching; the directory structure is assumed to be `<plex directory>/<user>/<album>/<media file>`. Metadata like `isFavorite` and lat/long are stored in a database.

## Prerequisites
You need `python3` and `pip3`. You might want Plex too!

## Usage
1. `$ python3 -m venv env` — create virtual environment
2. `$ . env/bin/activate` — turn it on
3. `$ (env) pip3 install -r requirements.txt` — install requirements in virtual environment
4. `$ (env) python3 serve.py` — start web server
5. Set up a cronjob that starts the web server if it isn't up. This is necessary because processes can spontaneously die for various reasons. Set an environment variable called `EDITOR` to whatever your favorite editor is. E.g., put `export EDITOR=emacs` at the bottom of `~/.bashrc` then source it. Run `crontab -e` to enter a new cronjob. E.g., `*/1 * * * * <path prefix>/sumu-backup/backend/start_sumu_backup.sh` will do a health check every minute and start the server if necessary. Alternatively, deploy this with Docker like a real person :-)

## To search the database
1. `$ (env) python3`
2. `>>> from app import models`
3. `>>> models.MediaMetadata.query.all()`
4. `>>> models.MediaMetadata.query.filter_by(isFavorite=True)`

## Album details
The frontend might decide to put images and videos in the same album directory. In fact, if an album name isn't given for a certain image or video, it currently defaults to the year and month in which it was taken, like `YY-MM`. That means that images and videos will often be mixed together. Live photos are uploaded as an image and a short video, and they're both stored in the same album.

Favorites are _copied_ instead of soft-linked to a special `favorites` album. Plex can't handle soft links; as of early 2020, its browser will show link targets but not sources. The expected behavior, of course, is showing both.
