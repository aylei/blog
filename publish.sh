#!/bin/zsh

hugo
cd ./docs/
git add .
git commit -m "update"
git push
cd ..
git add .
git commit -m $1
git push
