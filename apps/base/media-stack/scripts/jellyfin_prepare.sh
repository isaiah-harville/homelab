#!/bin/sh
set -eu

plugin_version="23.0.0.0"
plugin_dir="/config/plugins/LDAP Authentication_${plugin_version}"
plugin_archive="/tmp/ldap-authentication.zip"
plugin_url="https://repo.jellyfin.org/files/plugin/ldap-authentication/ldap-authentication_${plugin_version}.zip"
plugin_md5="e67eda7dd1b91a71315bd6620c8b03f1"

install -d -m 0750 -o 1000 -g 1000 \
  /config/plugins/configurations \
  "${plugin_dir}" \
  /media/downloads/incomplete \
  /media/downloads/complete \
  /media/library/movies

if [ ! -f "${plugin_dir}/LDAP-Auth.dll" ]; then
  apk add --no-cache ca-certificates curl unzip >/dev/null
  curl -fsSL "${plugin_url}" -o "${plugin_archive}"
  echo "${plugin_md5}  ${plugin_archive}" | md5sum -c -
  unzip -oq "${plugin_archive}" -d "${plugin_dir}"
fi

cat > /config/plugins/configurations/LDAP-Auth.xml <<EOF
<?xml version="1.0" encoding="utf-8"?>
<PluginConfiguration xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
  <LdapUsers />
  <LdapServer>authentik-ldap.apps.svc.cluster.local</LdapServer>
  <LdapPort>3389</LdapPort>
  <UseSsl>false</UseSsl>
  <UseStartTls>false</UseStartTls>
  <SkipSslVerify>false</SkipSslVerify>
  <LdapBindUser>cn=jellyfin-ldap-bind,ou=users,dc=media,dc=harville,dc=dev</LdapBindUser>
  <LdapBindPassword>${AUTHENTIK_LDAP_BIND_TOKEN}</LdapBindPassword>
  <LdapBaseDn>dc=media,dc=harville,dc=dev</LdapBaseDn>
  <LdapSearchFilter>(&amp;(objectClass=user)(memberOf=cn=Media Users,ou=groups,dc=media,dc=harville,dc=dev))</LdapSearchFilter>
  <LdapAdminBaseDn>dc=media,dc=harville,dc=dev</LdapAdminBaseDn>
  <LdapAdminFilter>(&amp;(objectClass=user)(memberOf=cn=authentik Admins,ou=groups,dc=media,dc=harville,dc=dev))</LdapAdminFilter>
  <EnableLdapAdminFilterMemberUid>false</EnableLdapAdminFilterMemberUid>
  <LdapSearchAttributes>uid,cn,mail,displayName</LdapSearchAttributes>
  <LdapClientCertPath />
  <LdapClientKeyPath />
  <LdapRootCaPath />
  <CreateUsersFromLdap>true</CreateUsersFromLdap>
  <AllowPassChange>false</AllowPassChange>
  <LdapUidAttribute>uid</LdapUidAttribute>
  <LdapUsernameAttribute>cn</LdapUsernameAttribute>
  <LdapPasswordAttribute>userPassword</LdapPasswordAttribute>
  <EnableLdapProfileImageSync>false</EnableLdapProfileImageSync>
  <RemoveImagesNotInLdap>false</RemoveImagesNotInLdap>
  <LdapProfileImageAttribute>jpegphoto</LdapProfileImageAttribute>
  <LdapProfileImageFormat>Default</LdapProfileImageFormat>
  <EnableAllFolders>true</EnableAllFolders>
  <EnabledFolders />
  <PasswordResetUrl>https://auth.harville.dev/if/user/</PasswordResetUrl>
</PluginConfiguration>
EOF

chown -R 1000:1000 /config/plugins "${plugin_dir}" /media/downloads /media/library
chmod 0600 /config/plugins/configurations/LDAP-Auth.xml
