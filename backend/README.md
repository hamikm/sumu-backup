You need `python3` and `pipenv`.

## To run webserver
1. Clone repo
2. `pipenv --three shell` — starts virtual environment
3. `pipenv install` — installs everything in `Pipfile` in virtual environment
4. `python serve.py` — runs server in virtual environment
5. Set up a cronjob to check if the web server is up and start it if it isn't. This is necessary because processes can spontaneously die for various reasons. E.g., `*/1 * * * * <path prefix>/sumu-backup/backend/start_sumu_backup.sh` will do a health check every minute and start the server if necessary.

## When updates require dependency changes
1. `pipenv --three shell` — starts virtual environment
2. `pipenv install <package>` — installs package
3. `pipenv lock` — freeze current dependencies into `Pipfile.lock`. Both `Pipfile*` files should be checked into version control.

## To search the database
1. `pipenv --three shell`
2. `python`
3. `from app import models`
4. `models.MediaMetadata.query.all()` or `models.MediaMetadata.query.filter_by(isFavorite=True).first()`
