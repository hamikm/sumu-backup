You need `python3` and `pipenv`.

## To run webserver
1. Clone repo
2. `pipenv --three shell` — starts virtual environment
3. `pipenv install` — installs everything in `Pipfile` in virtual environment
3. `python serve.py` — runs server in virtual environment

## When updates require dependency changes
1. `pipenv --three shell` — starts virtual environment
2. `pipenv install <package>` — installs package
3. `pipenv lock` — freeze current dependencies into `Pipfile.lock`. Both `Pipfile*` files should be checked into version control.