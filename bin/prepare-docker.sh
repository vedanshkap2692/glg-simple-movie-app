#!/usr/bin/env bash

function _which () {
  which "$1" > /dev/null
}

for cmd in base64 docker; do
  if ! _which "$cmd"; then
    echo "You must install the command '$cmd'" && exit 1
  fi
done

# docker-compose.yml reads .env.development; seed it from the checked-in template
if [ ! -f .env.development ]; then
  cp etc/dev.env .env.development
fi
