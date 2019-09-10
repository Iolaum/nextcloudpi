#!/bin/bash

set -e

## BACKWARD FIXES ( for older images )

source /usr/local/etc/library.sh # sets NCVER PHPVER RELEASE

# all images

# restore sources in stretch
sed -i "s/buster/$RELEASE/g" /etc/apt/sources.list.d/* &>/dev/null || true

# restore smbclient after dist upgrade
apt-get update
apt-get install -y --no-install-recommends php${PHPVER}-gmp

# docker images only
[[ -f /.docker-image ]] && {
  :
}

# for non docker images
[[ ! -f /.docker-image ]] && {
  :
}

exit 0
