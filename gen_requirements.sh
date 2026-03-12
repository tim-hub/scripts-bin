#!/bin/bash

# from poetry

poetry export --without-hashes --format=requirements.txt > requirements.txt
