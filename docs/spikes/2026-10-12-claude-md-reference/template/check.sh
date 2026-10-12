#!/bin/sh
echo "check ran $(date +%s)" >> .check-log
python3 -m unittest -q test_app
