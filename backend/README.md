You need `python3` and `pip3`.

## To run webserver
1. `git clone <https or ssh url>` - clone repo
2. `python3 -m venv sumu_env` — create virtual environment
3. `. sumu_env/bin/activate` — turn it on
4. `pip3 install -r requirements.txt` — install requirements in virtual environment
5. `python3 serve.py`
6. Set up a cronjob that checks if the web server is up and starts it if it isn't. This is necessary because processes can spontaneously die for various reasons. Set an environment variable called `EDITOR` to whatever your favorite editor is. E.g., put `export EDITOR=emacs` at the bottom of `~/.bashrc`. Then run `crontab -e`, where you can write cronjobs. E.g., `*/1 * * * * <path prefix>/sumu-backup/backend/start_sumu_backup.sh` will do a health check every minute and start the server if necessary.

## To search the database
1. `python3`
2. `from app import models`
4. `models.MediaMetadata.query.all()` or `models.MediaMetadata.query.filter_by(isFavorite=True).first()`
