if ps ax | grep -v grep | grep "python3 serve.py" > /dev/null
then
    exit
else
    cd /home/hamik/sumu-backup/backend
    . env/bin/activate
    python3 serve.py
fi
exit
