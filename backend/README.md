You need `python3` and `pipenv`.

## To run webserver
1. Clone repo
2. `pipenv --three install` — installs everything in `Pipfile` in virtual environment
3. `pipenv --three run python serve.py` — runs server in virtual environment. Use `pipenv --three shell` to turn on the virtual environment for all subsequent commands.

## When updates require dependencfy changes
1. `pipenv --three install <package>` — installs package
2. `pipenv --three lock` — freeze current dependencies into `Pipfile.lock`. Both `Pipfile*` files should be checked into version control.
