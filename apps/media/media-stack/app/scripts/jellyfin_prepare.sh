#!/bin/sh
set -eu

ldap_plugin_version="23.0.0.0"
ldap_plugin_dir="/config/plugins/LDAP Authentication_${ldap_plugin_version}"
ldap_plugin_archive="/tmp/ldap-authentication.zip"
ldap_plugin_url="https://repo.jellyfin.org/files/plugin/ldap-authentication/ldap-authentication_${ldap_plugin_version}.zip"
ldap_plugin_md5="e67eda7dd1b91a71315bd6620c8b03f1"
sso_plugin_version="4.0.0.4"
sso_plugin_dir="/config/plugins/SSO-Auth_${sso_plugin_version}"
sso_plugin_archive="/tmp/sso-authentication.zip"
sso_plugin_url="https://github.com/9p4/jellyfin-plugin-sso/releases/download/v${sso_plugin_version}/sso-authentication_${sso_plugin_version}.zip"
sso_plugin_md5="1e7908585ebee256203a0869dcdfbaf8"

install -d -m 0750 -o 1000 -g 1000 \
  /config/plugins/configurations \
  /config/config \
  "${ldap_plugin_dir}" \
  "${sso_plugin_dir}" \
  /media/downloads/incomplete \
  /media/downloads/complete \
  /media/library/movies

if [ ! -f "${ldap_plugin_dir}/LDAP-Auth.dll" ]; then
  apk add --no-cache ca-certificates curl unzip >/dev/null
  curl -fsSL "${ldap_plugin_url}" -o "${ldap_plugin_archive}"
  echo "${ldap_plugin_md5}  ${ldap_plugin_archive}" | md5sum -c -
  unzip -oq "${ldap_plugin_archive}" -d "${ldap_plugin_dir}"
fi

if [ ! -f "${sso_plugin_dir}/SSO-Auth.dll" ]; then
  apk add --no-cache ca-certificates curl unzip >/dev/null
  curl -fsSL "${sso_plugin_url}" -o "${sso_plugin_archive}"
  echo "${sso_plugin_md5}  ${sso_plugin_archive}" | md5sum -c -
  unzip -oq "${sso_plugin_archive}" -d "${sso_plugin_dir}"
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

cat > /config/plugins/configurations/SSO-Auth.xml <<EOF
<?xml version="1.0" encoding="utf-8"?>
<PluginConfiguration xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
  <SamlConfigs />
  <OidConfigs>
    <item>
      <key><string>authentik</string></key>
      <value>
        <PluginConfiguration>
          <OidEndpoint>https://auth.harville.dev/application/o/jellyfin-oidc/</OidEndpoint>
          <OidClientId>${JELLYFIN_OIDC_CLIENT_ID}</OidClientId>
          <OidSecret>${JELLYFIN_OIDC_CLIENT_SECRET}</OidSecret>
          <Enabled>true</Enabled>
          <EnableAuthorization>true</EnableAuthorization>
          <EnableAllFolders>true</EnableAllFolders>
          <EnabledFolders />
          <AdminRoles><string>authentik Admins</string></AdminRoles>
          <Roles><string>Media Users</string><string>authentik Admins</string></Roles>
          <EnableFolderRoles>false</EnableFolderRoles>
          <EnableLiveTvRoles>false</EnableLiveTvRoles>
          <EnableLiveTv>false</EnableLiveTv>
          <EnableLiveTvManagement>false</EnableLiveTvManagement>
          <LiveTvRoles />
          <LiveTvManagementRoles />
          <FolderRoleMappings />
          <RoleClaim>groups</RoleClaim>
          <OidScopes><string>groups</string></OidScopes>
          <DefaultProvider>Jellyfin.Plugin.LDAP_Auth.LdapAuthenticationProviderPlugin</DefaultProvider>
          <SchemeOverride>https</SchemeOverride>
          <NewPath>false</NewPath>
          <CanonicalLinks />
          <DefaultUsernameClaim>preferred_username</DefaultUsernameClaim>
          <DisableHttps>false</DisableHttps>
          <DisablePushedAuthorization>false</DisablePushedAuthorization>
          <DoNotValidateEndpoints>false</DoNotValidateEndpoints>
          <DoNotValidateIssuerName>false</DoNotValidateIssuerName>
          <DoNotLoadProfile>false</DoNotLoadProfile>
        </PluginConfiguration>
      </value>
    </item>
  </OidConfigs>
</PluginConfiguration>
EOF

# The legacy /p route and /r callback are the mutually consistent paths in
# SSO-Auth 4.0.0.4. The provider also permits the newer aliases for upgrades.
cat > /config/config/branding.xml <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<BrandingOptions xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
  <LoginDisclaimer>&lt;a class="raised button-submit block emby-button" href="https://watch.harville.dev/sso/OID/p/authentik"&gt;Sign in with Authentik&lt;/a&gt;</LoginDisclaimer>
  <CustomCss>/* The login disclaimer is sanitised into a &lt;p&gt; and the anchor is upgraded
   to an emby-linkbutton, which adds .button-link. That class sets padding to 0
   and colour to #00a4dc — the same blue as .button-submit's background — so the
   stock button collapses to a thin bar with its label invisible against itself.
   Two classes here to outrank .button-link's single class. */
.loginDisclaimer p { margin: 0; }
.loginDisclaimer .emby-button {
  display: flex;
  align-items: center;
  justify-content: center;
  box-sizing: border-box;
  width: 100%;
  margin: 0;
  padding: 0.9em 1em;
  background: #00a4dc;
  color: #fff;
  text-decoration: none;
}
.loginDisclaimer .emby-button:hover,
.loginDisclaimer .emby-button:focus { background: #0587b5; color: #fff; }</CustomCss>
  <SplashscreenEnabled>true</SplashscreenEnabled>
  <SplashscreenLocation>/config/data/splashscreen-upload.jpg</SplashscreenLocation>
</BrandingOptions>
EOF

chown -R 1000:1000 /config/plugins /config/config "${ldap_plugin_dir}" "${sso_plugin_dir}" /media/downloads /media/library
chmod 0600 /config/plugins/configurations/LDAP-Auth.xml
chmod 0600 /config/plugins/configurations/SSO-Auth.xml /config/config/branding.xml
