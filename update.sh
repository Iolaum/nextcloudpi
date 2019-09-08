#!/bin/bash

# Updater for NextCloudPi
#
# Copyleft 2017 by Ignacio Nunez Hernanz <nacho _a_t_ ownyourbits _d_o_t_ com>
# GPL licensed (see end of file) * Use at your own risk!
#
# More at https://ownyourbits.com/
#

set -e

CONFDIR=/usr/local/etc/ncp-config.d/
UPDATESDIR=updates

# don't make sense in a docker container
EXCL_DOCKER="
nc-automount
nc-format-USB
nc-datadir
nc-database
nc-ramlogs
nc-swapfile
nc-static-IP
nc-wifi
nc-nextcloud
nc-init
UFW
nc-snapshot
nc-snapshot-auto
nc-snapshot-sync
nc-restore-snapshot
nc-audit
nc-hdd-monitor
nc-zram
SSH
fail2ban
NFS
"

# better use a designated container
EXCL_DOCKER+="
samba
"

# check running apt
pgrep apt &>/dev/null && { echo "apt is currently running. Try again later";  exit 1; }

cp etc/library.sh /usr/local/etc/

source /usr/local/etc/library.sh

mkdir -p "$CONFDIR"

# prevent installing some ncp-apps in the docker version
[[ -f /.docker-image ]] && {
  for opt in $EXCL_DOCKER; do
    touch $CONFDIR/$opt.cfg
  done
}

# copy all files in bin and etc
cp -r bin/* /usr/local/bin/
find etc -maxdepth 1 -type f ! -path etc/ncp.cfg -exec cp '{}' /usr/local/etc \;

# set initial config # TODO remove me after next NCP release
[[ -f "${NCPCFG}" ]] || cat > /usr/local/etc/ncp.cfg <<EOF
{
	"nextcloud_version": "16.0.2",
	"php_version": "7.2",
	"release": "stretch",
	"release_issue": [
		"Debian GNU/Linux 9",
		"Raspbian GNU/Linux 9"
	]
}
EOF
cp -n etc/ncp.cfg /usr/local/etc

# install new entries of ncp-config and update others
for file in etc/ncp-config.d/*; do
  [ -f "$file" ] || continue;    # skip dirs

  # install new ncp_apps
  [ -f /usr/local/"$file" ] || {
    install_app "$(basename "$file" .cfg)"
  }

  # keep saved cfg values
  [ -f /usr/local/"$file" ] && {
    len="$(jq '.params | length' /usr/local/"$file")"
    for (( i = 0 ; i < len ; i++ )); do
      val="$(jq -r ".params[$i].value" /usr/local/"$file")"
      cfg="$(jq ".params[$i].value = \"$val\"" "$file")"
      echo "$cfg" > "$file"
    done
  }

  # configure if active by default
  [ -f /usr/local/"$file" ] || {
    [[ "$(jq -r ".params[0].id"    "$file")" == "ACTIVE" ]] && \
    [[ "$(jq -r ".params[0].value" "$file")" == "yes"    ]] && {
      cp "$file" /usr/local/"$file"
      run_app "$(basename "$file" .cfg)"
    }
  }

  cp "$file" /usr/local/"$file"

done

# update NCVER in ncp.cfg and nc-nextcloud.cfg (for nc-autoupdate-nc and nc-update-nextcloud)
nc_version=$(jq -r .nextcloud_version < etc/ncp.cfg)
cfg="$(jq '.' /usr/local/etc/ncp.cfg)"
cfg="$(jq ".nextcloud_version = \"$nc_version\"" <<<"$cfg")"
echo "$cfg" > /usr/local/etc/ncp.cfg

cfg="$(jq '.' etc/ncp-config.d/nc-nextcloud.cfg)"
cfg="$(jq ".params[0].value = \"$nc_version\"" <<<"$cfg")"
echo "$cfg" > /usr/local/etc/ncp-config.d/nc-nextcloud.cfg

# install localization files
cp -rT etc/ncp-config.d/l10n "$CONFDIR"/l10n

# these files can contain sensitive information, such as passwords
chown -R root:www-data "$CONFDIR"
chmod 660 "$CONFDIR"/*
chmod 750 "$CONFDIR"/l10n

# install web interface
cp -r ncp-web /var/www/
chown -R www-data:www-data /var/www/ncp-web
chmod 770                  /var/www/ncp-web

# install NC app
rm -rf /var/www/ncp-app
cp -r ncp-app /var/www/

# copy NC app to nextcloud directory and enable it
rm -rf /var/www/nextcloud/apps/nextcloudpi
cp -r /var/www/ncp-app /var/www/nextcloud/apps/nextcloudpi
chown -R www-data:     /var/www/nextcloud/apps/nextcloudpi

[[ -f /.docker-image ]] && {
  # remove unwanted ncp-apps for the docker version
  for opt in $EXCL_DOCKER; do
    rm $CONFDIR/$opt.cfg
    find /usr/local/bin/ncp -name "$opt.sh" -exec rm '{}' \;
  done

  # update services
  cp docker/{lamp/010lamp,nextcloud/020nextcloud,nextcloudpi/000ncp} /etc/services-enabled.d
}

# only live updates from here
[[ -f /.ncp-image ]] && exit 0

# update old images
./run_update_history.sh "$UPDATESDIR"

# update to the latest NC version
is_active_app nc-autoupdate-nc && run_app nc-autoupdate-nc

# check dist-upgrade
check_distro "$NCPCFG" && check_distro etc/ncp.cfg || {
  php_ver_new=$(jq -r '.php_version'   < etc/ncp.cfg)
  release_new=$(jq -r '.release'       < etc/ncp.cfg)

  cfg="$(jq '.' "$NCPCFG")"
  cfg="$(jq '.php_version   = "'$php_ver_new'"' <<<"$cfg")"
  cfg="$(jq '.release       = "'$release_new'"' <<<"$cfg")"
  echo "$cfg" > /usr/local/etc/ncp-recommended.cfg

  [[ -f /.dockerenv ]] && \
    msg="Update to $release_new available. Get the latest container to upgrade" || \
    msg="Update to $release_new available. Type 'sudo ncp-dist-upgrade' to upgrade"
  echo "${msg}"
  ncc notification:generate "ncp" "New distribution available" -l "${msg}"
  wall "${msg}"
  cat > /etc/update-motd.d/30ncp-dist-upgrade <<EOF
#!/bin/bash
new_cfg=/usr/local/etc/ncp-recommended.cfg
[[ -f "\${new_cfg}" ]] || exit 0
echo -e "${msg}"
EOF
chmod +x /etc/update-motd.d/30ncp-dist-upgrade
}

# Update modsecurity config file only if user is already in buster and is used.
# https://github.com/nextcloud/nextcloudpi/issues/959
check_distro "$NCPCFG" && {
  [[ -f /etc/modsecurity/modsecurity_crs_99_whitelist.conf ]] && {
    cat > /etc/modsecurity/modsecurity_crs_99_whitelist.conf <<EOF
<Directory $NCDIR>
  # VIDEOS
  SecRuleRemoveById 958291             # Range Header Checks
  SecRuleRemoveById 980120             # Correlated Attack Attempt

  # PDF
  SecRuleRemoveById 920230             # Check URL encodings

  # ADMIN (webdav)
  SecRuleRemoveById 960024             # Repeatative Non-Word Chars (heuristic)
  SecRuleRemoveById 981173             # SQL Injection Character Anomaly Usage
  SecRuleRemoveById 980130             # Correlated Attack Attempt
  SecRuleRemoveById 981243             # PHPIDS - Converted SQLI Filters
  SecRuleRemoveById 981245             # PHPIDS - Converted SQLI Filters
  SecRuleRemoveById 981246             # PHPIDS - Converted SQLI Filters
  SecRuleRemoveById 981318             # String Termination/Statement Ending Injection Testing
  SecRuleRemoveById 973332             # XSS Filters from IE
  SecRuleRemoveById 973338             # XSS Filters - Category 3
  SecRuleRemoveById 981143             # CSRF Protections ( TODO edit LocationMatch filter )

  # COMING BACK FROM OLD SESSION
  SecRuleRemoveById 970903             # Microsoft Office document properties leakage

  # NOTES APP
  SecRuleRemoveById 981401             # Content-Type Response Header is Missing and X-Content-Type-Options is either missing or not set to 'nosniff'
  SecRuleRemoveById 200002             # Failed to parse request body

  # UPLOADS ( https://github.com/nextcloud/nextcloudpi/issues/959#issuecomment-529150562 )
  SecRequestBodyNoFilesLimit 536870912

  # GENERAL
  SecRuleRemoveById 920350             # Host header is a numeric IP address

  # REGISTERED WARNINGS, BUT DID NOT HAVE TO DISABLE THEM
  #SecRuleRemoveById 981220 900046 981407
  #SecRuleRemoveById 981222 981405 981185 949160

</Directory>
<Directory $NCPWB>
  # GENERAL
  SecRuleRemoveById 920350             # Host header is a numeric IP address
</Directory>
EOF
    # restart apache2 so changes take effect
    sleep 2 && service apache2 reload &>/dev/null
  }
}

exit 0

# License
#
# This script is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This script is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this script; if not, write to the
# Free Software Foundation, Inc., 59 Temple Place, Suite 330,
# Boston, MA  02111-1307  USA
