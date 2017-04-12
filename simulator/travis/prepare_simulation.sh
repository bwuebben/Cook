#!/bin/bash
set -ev

export PROJECT_DIR=`pwd`

lein deps

../travis/prepare.sh

docker pull python:3
