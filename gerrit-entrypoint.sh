#!/usr/bin/env sh
set -e

set_gerrit_config() {
  su-exec ${GERRIT_USER} git config -f "${GERRIT_SITE}/etc/gerrit.config" "$@"
}

set_secure_config() {
  su-exec ${GERRIT_USER} git config -f "${GERRIT_SITE}/etc/secure.config" "$@"
}

set_replication_config() {
  su-exec ${GERRIT_USER} git config -f "${GERRIT_SITE}/etc/replication.config" "$@"
}

wait_for_database() {
  echo "Waiting for database connection $1:$2 ..."
  until nc -z $1 $2; do
    sleep 1
  done

  # Wait to avoid "panic: Failed to open sql connection pq: the database system is starting up"
  sleep 1
}

if [ -n "${JAVA_HEAPLIMIT}" ]; then
  JAVA_MEM_OPTIONS="-Xmx${JAVA_HEAPLIMIT}"
fi

if [ "$1" = "/gerrit-start.sh" ]; then
  # If you're mounting ${GERRIT_SITE} to your host, you this will default to root.
  # This obviously ensures the permissions are set correctly for when gerrit starts.
  find "${GERRIT_SITE}/" ! -user `id -u ${GERRIT_USER}` -exec chown ${GERRIT_USER} {} \;

  # Initialize Gerrit if ${GERRIT_SITE}/git is empty.
  if [ -z "$(ls -A "$GERRIT_SITE/git")" ]; then
    echo "First time initialize gerrit..."
    su-exec ${GERRIT_USER} java ${JAVA_OPTIONS} ${JAVA_MEM_OPTIONS} -jar "${GERRIT_WAR}" init --install-all-plugins --batch --no-auto-start -d "${GERRIT_SITE}" ${GERRIT_INIT_ARGS}
    #All git repositories must be removed when database is set as postgres or mysql
    #in order to be recreated at the secondary init below.
    #Or an execption will be thrown on secondary init.
    [ ${#DATABASE_TYPE} -gt 0 ] && rm -rf "${GERRIT_SITE}/git"
  fi

  # Install external plugins
  su-exec ${GERRIT_USER} cp -f ${GERRIT_HOME}/delete-project.jar ${GERRIT_SITE}/plugins/delete-project.jar
  su-exec ${GERRIT_USER} cp -f ${GERRIT_HOME}/events-log.jar ${GERRIT_SITE}/plugins/events-log.jar
  #su-exec ${GERRIT_USER} cp -f ${GERRIT_HOME}/importer.jar ${GERRIT_SITE}/plugins/importer.jar

  # Provide a way to customise this image
  echo
  for f in /docker-entrypoint-init.d/*; do
    case "$f" in
      *.sh)    echo "$0: running $f"; source "$f" ;;
      *.nohup) echo "$0: running $f"; nohup  "$f" & ;;
      *)       echo "$0: ignoring $f" ;;
    esac
    echo
  done

  #Replication config
  if [ -n "${REPLICATION_REMOTES}" ]; then
    set_replication_config gerrit.autoReload "true"
    [ -z "${REPLICATE_ON_STARTUP}" ]    || set_replication_config gerrit.replicateOnStartup "${REPLICATE_ON_STARTUP}"
    [ -z "${REPLICATION_MAX_RETRIES}" ] || set_replication_config replication.maxRetries "${REPLICATION_MAX_RETRIES}"

    for r in ${REPLICATION_REMOTES}; do
      URL=`eval      $(echo echo \\$$(echo "${r}_URL"     | awk '{print toupper($0)}'))`
      MIRROR=`eval   $(echo echo \\$$(echo "${r}_MIRROR"  | awk '{print toupper($0)}'))`
      PROJECTS=`eval $(echo echo \\$$(echo "${r}_PROJECTS"| awk '{print toupper($0)}'))`
      TIMEOUT=`eval  $(echo echo \\$$(echo "${r}_TIMEOUT" | awk '{print toupper($0)}'))`
      THREADS=`eval  $(echo echo \\$$(echo "${r}_THREADS" | awk '{print toupper($0)}'))`

      RESCHEDULE_DELAY=`eval $(echo echo \\$$(echo "${r}_RESCHEDUL_DELAY" | awk '{print toupper($0)}'))`

      REPLICATION_DELAY=`eval       $(echo echo \\$$(echo "${r}_REPLICATION_DELAY"       | awk '{print toupper($0)}'))`
      REPLICATION_RETRY=`eval       $(echo echo \\$$(echo "${r}_REPLICATION_RETRY"       | awk '{print toupper($0)}'))`
      REPLICATION_MAX_RETRIES=`eval $(echo echo \\$$(echo "${r}_REPLICATION_MAX_RETRIES" | awk '{print toupper($0)}'))`

      REPLICATE_PERMISSIONS=`eval $(echo echo \\$$(echo "${r}_REPLICATE_PERMISSIONS" | awk '{print toupper($0)}'))`

      CREATE_MISSING_REPOSITORIES=`eval $(echo echo \\$$(echo "${r}_CREATE_MISSING_REPOSITORIES" | awk '{print toupper($0)}'))`

      USERNAME=`eval $(echo echo \\$$(echo "${r}_USERNAME"| awk '{print toupper($0)}'))`
      PASSWORD=`eval $(echo echo \\$$(echo "${r}_PASSWORD"| awk '{print toupper($0)}'))`

      [ -z "${URL}" ]           || set_replication_config remote.${r}.url "${URL}"
      [ -z "${MIRROR}" ]           || set_replication_config remote.${r}.mirror "${MIRROR}"
      [ -z "${TIMEOUT}" ]          || set_replication_config remote.${r}.timeout "${TIMEOUT}"
      [ -z "${THREADS}" ]          || set_replication_config remote.${r}.threads "${THREADS}"
      [ -z "${RESCHEDULE_DELAY}" ] || set_replication_config remote.${r}.rescheduleDelay "${RESCHEDULE_DELAY}"

      [ -z "${REPLICATION_DELAY}" ]       || set_replication_config remote.${r}.replicationDelay "${REPLICATION_DELAY}"
      [ -z "${REPLICATION_RETRY}" ]       || set_replication_config remote.${r}.replicationRetry "${REPLICATION_RETRY}"
      [ -z "${REPLICATION_MAX_RETRIES}" ] || set_replication_config remote.${r}.replicationMaxRetries "${REPLICATION_MAX_RETRIES}"

      [ -z "${REPLICATE_PERMISSIONS}" ] || set_replication_config remote.${r}.replicatePermissions "${REPLICATE_PERMISSIONS}"

      [ -z "${CREATE_MISSING_REPOSITORIES}" ] || set_replication_config remote.${r}.createMissingRepositories "${CREATE_MISSING_REPOSITORIES}"

      [ -z "${USERNAME}" ] || set_secure_config remote.${r}.username "${USERNAME}"
      [ -z "${PASSWORD}" ] || set_secure_config remote.${r}.password "${PASSWORD}"

      if ! $(git config -f "${GERRIT_SITE}/etc/replication.config" --get-all remote.${r}.projects > /dev/null); then
        for p in ${PROJECTS}; do
          set_replication_config --add remote.${r}.projects "${p}"
        done
      fi

      if ! $(git config -f "${GERRIT_SITE}/etc/replication.config" --get-all remote.${r}.push > /dev/null); then
        set_replication_config --add remote.${r}.push "+refs/heads/*:refs/heads/*"
        set_replication_config --add remote.${r}.push "+refs/tags/*:refs/tags/*"
      fi
    done
  fi

  #Customize gerrit.config
  #Section download
  if [ -n "${DOWNLOAD_SCHEMES}" ]; then
    set_gerrit_config --unset-all download.scheme || true
    for s in ${DOWNLOAD_SCHEMES}; do
      set_gerrit_config --add download.scheme ${s}
    done
  fi

  #Section gerrit
  [ -z "${UI}" ]             || set_gerrit_config gerrit.ui "${UI}"
  [ -z "${GWT_UI}" ]         || set_gerrit_config gerrit.enableGwtUi "${GWT_UI}"
  [ -z "${WEBURL}" ]         || set_gerrit_config gerrit.canonicalWebUrl "${WEBURL}"
  [ -z "${GITURL}" ]         || set_gerrit_config gerrit.canonicalGitUrl "${GITURL}"
  [ -z "${DOCURL}" ]         || set_gerrit_config gerrit.docUrl "${DOCURL}"
  [ -z "${GITHTTPURL}" ]     || set_gerrit_config gerrit.gitHttpUrl "${GITHTTPURL}"
  if [ -n "${BUGURL}" ]; then   set_gerrit_config gerrit.reportBugUrl "${BUGURL}"
    [ -z "${BUGTEXT}" ]      || set_gerrit_config gerrit.reportBugText "${BUGTEXT}"
  fi
  [ -z "${SERVER_ID}" ]      || set_gerrit_config gerrit.serverId "${SERVER_ID}"
  [ -z "${EDIT_GPG}" ]       || set_gerrit_config gerrit.editGpgKeys "${EDIT_GPG}"
  [ -z "${IFRAME}" ]         || set_gerrit_config gerrit.canLoadInIFrame "${IFRAME}"
  [ -z "${CDN_PATH}" ]       || set_gerrit_config gerrit.cdnPath "${CDN_PATH}"
  [ -z "${BASE_PATH}" ]      || set_gerrit_config gerrit.basePath "${BASE_PATH}"
  [ -z "${FAVICON_PATH}" ]   || set_gerrit_config gerrit.faviconPath "${FAVICON_PATH}"
  [ -z "${ALL_USERS}" ]      || set_gerrit_config gerrit.allUsers "${ALL_USERS}"
  [ -z "${ALL_PROJECTS}" ]   || set_gerrit_config gerrit.allProjects "${ALL_PROJECTS}"
  [ -z "${INSTANCE_NAME}" ]  || set_gerrit_config gerrit.instanceName "${INSTANCE_NAME}"
  [ -z "${INSTALL_MODULE}" ] || set_gerrit_config gerrit.installModule "${INSTALL_MODULE}"

  [ -z "${SECURE_STORE_CLASS}" ]         || set_gerrit_config gerrit.secureStoreClass "${SECURE_STORE_CLASS}"
  [ -z "${INSTALL_COMMIT_MSG_HOOK}" ]    || set_gerrit_config gerrit.installCommitMsgHookCommand "${INSTALL_COMMIT_MSG_HOOK}"
  [ -z "${DISABLE_REVERSE_DNS_LOOKUP}" ] || set_gerrit_config gerrit.disableReverseDnsLookup "$DISABLE_REVERSE_DNS_LOOKUP}"

  [ -z "${PRIMARY_WEBLINK_NAME}" ]     || set_gerrit_config gerrit.primaryWeblinkName "${PRIMARY_WEBLINK_NAME}"
  [ -z "${LIST_PROJECTS_FROM_INDEX}" ] || set_gerrit_config gerrit.listProjectsFromIndex "${LIST_PROJECTS_FROM_INDEX}"

  #Section sshd
  [ -z "${LISTEN_ADDR}" ]             || set_gerrit_config sshd.listenAddress "${LISTEN_ADDR}"
  [ -z "${SSHD_ADVERTISE_ADDR}" ]     || set_gerrit_config sshd.advertisedAddress "${SSHD_ADVERTISE_ADDR}"
  [ -z "${SSHD_ENABLE_COMPRESSION}" ] || set_gerrit_config sshd.enableCompression "${SSHD_ENABLE_COMPRESSION}"
  [ -z "${SSHD_THREADS}" ]            || set_gerrit_config sshd.threads "${SSHD_THREADS}"

  #Section database
  if [ "${DATABASE_TYPE}" = 'postgresql' ]; then
    [ -z "${DB_PORT_5432_TCP_ADDR}" ]    || set_gerrit_config database.hostname "${DB_PORT_5432_TCP_ADDR}"
    [ -z "${DB_PORT_5432_TCP_PORT}" ]    || set_gerrit_config database.port "${DB_PORT_5432_TCP_PORT}"
    [ -z "${DB_ENV_POSTGRES_DB}" ]       || set_gerrit_config database.database "${DB_ENV_POSTGRES_DB}"
    [ -z "${DB_ENV_POSTGRES_USER}" ]     || set_gerrit_config database.username "${DB_ENV_POSTGRES_USER}"
    [ -z "${DB_ENV_POSTGRES_PASSWORD}" ] || set_secure_config database.password "${DB_ENV_POSTGRES_PASSWORD}"
  fi

  if [ "${DATABASE_TYPE}" = 'mysql' ]; then
    [ -z "${DB_PORT_3306_TCP_ADDR}" ] || set_gerrit_config database.hostname "${DB_PORT_3306_TCP_ADDR}"
    [ -z "${DB_PORT_3306_TCP_PORT}" ] || set_gerrit_config database.port "${DB_PORT_3306_TCP_PORT}"
    [ -z "${DB_ENV_MYSQL_DB}" ]       || set_gerrit_config database.database "${DB_ENV_MYSQL_DB}"
    [ -z "${DB_ENV_MYSQL_USER}" ]     || set_gerrit_config database.username "${DB_ENV_MYSQL_USER}"
    [ -z "${DB_ENV_MYSQL_PASSWORD}" ] || set_secure_config database.password "${DB_ENV_MYSQL_PASSWORD}"
  fi

  # docker --link is deprecated. All DB_* environment variables will be replaced by DATABASE_* below.
  # All kinds of database.type are supported.
  [ -z "${DATABASE_TYPE}" ]     || set_gerrit_config database.type     "${DATABASE_TYPE}"
  [ -z "${DATABASE_HOSTNAME}" ] || set_gerrit_config database.hostname "${DATABASE_HOSTNAME}"
  [ -z "${DATABASE_PORT}" ]     || set_gerrit_config database.port     "${DATABASE_PORT}"
  [ -z "${DATABASE_DATABASE}" ] || set_gerrit_config database.database "${DATABASE_DATABASE}"
  [ -z "${DATABASE_USERNAME}" ] || set_gerrit_config database.username "${DATABASE_USERNAME}"
  [ -z "${DATABASE_PASSWORD}" ] || set_secure_config database.password "${DATABASE_PASSWORD}"
  # JDBC URL
  [ -z "${DATABASE_URL}" ] || set_gerrit_config database.url "${DATABASE_URL}"
  # Other database options
  [ -z "${DATABASE_CONNECTION_POOL}" ] || set_secure_config database.connectionPool "${DATABASE_CONNECTION_POOL}"
  [ -z "${DATABASE_POOL_LIMIT}" ]      || set_secure_config database.poolLimit "${DATABASE_POOL_LIMIT}"
  [ -z "${DATABASE_POOL_MIN_IDLE}" ]   || set_secure_config database.poolMinIdle "${DATABASE_POOL_MIN_IDLE}"
  [ -z "${DATABASE_POOL_MAX_IDLE}" ]   || set_secure_config database.poolMaxIdle "${DATABASE_POOL_MAX_IDLE}"
  [ -z "${DATABASE_POOL_MAX_WAIT}" ]   || set_secure_config database.poolMaxWait "${DATABASE_POOL_MAX_WAIT}"

  #Section noteDB
  [ -z "${NOTEDB_ACCOUNTS_SEQUENCEBATCHSIZE}" ] || set_gerrit_config noteDB.accounts.sequenceBatchSize "${NOTEDB_ACCOUNTS_SEQUENCEBATCHSIZE}"
  [ -z "${NOTEDB_CHANGES_AUTOMIGRATE}" ]        || set_gerrit_config noteDB.changes.autoMigrate "${NOTEDB_CHANGES_AUTOMIGRATE}"

  #Section auth
  [ -z "${AUTH_TYPE}" ]                  || set_gerrit_config auth.type "${AUTH_TYPE}"
  [ -z "${AUTH_HTTP_HEADER}" ]           || set_gerrit_config auth.httpHeader "${AUTH_HTTP_HEADER}"
  [ -z "${AUTH_EMAIL_FORMAT}" ]          || set_gerrit_config auth.emailFormat "${AUTH_EMAIL_FORMAT}"
  if [ -z "${AUTH_GIT_BASIC_AUTH_POLICY}" ]; then
    case "${AUTH_TYPE}" in
      LDAP|LDAP_BIND)
        set_gerrit_config auth.gitBasicAuthPolicy "LDAP"
        ;;
      HTTP|HTTP_LDAP)
        set_gerrit_config auth.gitBasicAuthPolicy "${AUTH_TYPE}"
        ;;
      *)
    esac
  else
    set_gerrit_config auth.gitBasicAuthPolicy "${AUTH_GIT_BASIC_AUTH_POLICY}"
  fi

  # Set OAuth provider
  if [ "${AUTH_TYPE}" = 'OAUTH' ]; then
    [ -z "${AUTH_GIT_OAUTH_PROVIDER}" ] || set_gerrit_config auth.gitOAuthProvider "${AUTH_GIT_OAUTH_PROVIDER}"
  fi

  if [ -z "${AUTH_TYPE}" ] || [ "${AUTH_TYPE}" = 'OpenID' ] || [ "${AUTH_TYPE}" = 'OpenID_SSO' ]; then
    [ -z "${AUTH_ALLOWED_OPENID}" ] || set_gerrit_config auth.allowedOpenID "${AUTH_ALLOWED_OPENID}"
    [ -z "${AUTH_TRUSTED_OPENID}" ] || set_gerrit_config auth.trustedOpenID "${AUTH_TRUSTED_OPENID}"
    [ -z "${AUTH_OPENID_DOMAIN}" ]  || set_gerrit_config auth.openIdDomain "${AUTH_OPENID_DOMAIN}"
  fi

  #Section ldap
  if [ "${AUTH_TYPE}" = 'LDAP' ] || [ "${AUTH_TYPE}" = 'LDAP_BIND' ] || [ "${AUTH_TYPE}" = 'HTTP_LDAP' ]; then
    [ -z "${LDAP_SERVER}" ]                   || set_gerrit_config ldap.server "${LDAP_SERVER}"
    [ -z "${LDAP_SSLVERIFY}" ]                || set_gerrit_config ldap.sslVerify "${LDAP_SSLVERIFY}"
    [ -z "${LDAP_GROUPSVISIBLETOALL}" ]       || set_gerrit_config ldap.groupsVisibleToAll "${LDAP_GROUPSVISIBLETOALL}"
    [ -z "${LDAP_USERNAME}" ]                 || set_gerrit_config ldap.username "${LDAP_USERNAME}"
    [ -z "${LDAP_PASSWORD}" ]                 || set_secure_config ldap.password "${LDAP_PASSWORD}"
    [ -z "${LDAP_REFERRAL}" ]                 || set_gerrit_config ldap.referral "${LDAP_REFERRAL}"
    [ -z "${LDAP_READTIMEOUT}" ]              || set_gerrit_config ldap.readTimeout "${LDAP_READTIMEOUT}"
    [ -z "${LDAP_ACCOUNTBASE}" ]              || set_gerrit_config ldap.accountBase "${LDAP_ACCOUNTBASE}"
    [ -z "${LDAP_ACCOUNTSCOPE}" ]             || set_gerrit_config ldap.accountScope "${LDAP_ACCOUNTSCOPE}"
    [ -z "${LDAP_ACCOUNTPATTERN}" ]           || set_gerrit_config ldap.accountPattern "${LDAP_ACCOUNTPATTERN}"
    [ -z "${LDAP_ACCOUNTFULLNAME}" ]          || set_gerrit_config ldap.accountFullName "${LDAP_ACCOUNTFULLNAME}"
    [ -z "${LDAP_ACCOUNTEMAILADDRESS}" ]      || set_gerrit_config ldap.accountEmailAddress "${LDAP_ACCOUNTEMAILADDRESS}"
    [ -z "${LDAP_ACCOUNTSSHUSERNAME}" ]       || set_gerrit_config ldap.accountSshUserName "${LDAP_ACCOUNTSSHUSERNAME}"
    [ -z "${LDAP_ACCOUNTMEMBERFIELD}" ]       || set_gerrit_config ldap.accountMemberField "${LDAP_ACCOUNTMEMBERFIELD}"
    [ -z "${LDAP_FETCHMEMBEROFEAGERLY}" ]     || set_gerrit_config ldap.fetchMemberOfEagerly "${LDAP_FETCHMEMBEROFEAGERLY}"
    [ -z "${LDAP_GROUPBASE}" ]                || set_gerrit_config ldap.groupBase "${LDAP_GROUPBASE}"
    [ -z "${LDAP_GROUPSCOPE}" ]               || set_gerrit_config ldap.groupScope "${LDAP_GROUPSCOPE}"
    [ -z "${LDAP_GROUPPATTERN}" ]             || set_gerrit_config ldap.groupPattern "${LDAP_GROUPPATTERN}"
    [ -z "${LDAP_GROUPMEMBERPATTERN}" ]       || set_gerrit_config ldap.groupMemberPattern "${LDAP_GROUPMEMBERPATTERN}"
    [ -z "${LDAP_GROUPNAME}" ]                || set_gerrit_config ldap.groupName "${LDAP_GROUPNAME}"
    [ -z "${LDAP_LOCALUSERNAMETOLOWERCASE}" ] || set_gerrit_config ldap.localUsernameToLowerCase "${LDAP_LOCALUSERNAMETOLOWERCASE}"
    [ -z "${LDAP_AUTHENTICATION}" ]           || set_gerrit_config ldap.authentication "${LDAP_AUTHENTICATION}"
    [ -z "${LDAP_USECONNECTIONPOOLING}" ]     || set_gerrit_config ldap.useConnectionPooling "${LDAP_USECONNECTIONPOOLING}"
    [ -z "${LDAP_CONNECTTIMEOUT}" ]           || set_gerrit_config ldap.connectTimeout "${LDAP_CONNECTTIMEOUT}"
  fi

  #Section OAUTH general
  if [ "${AUTH_TYPE}" = 'OAUTH' ]  ; then
    su-exec ${GERRIT_USER} cp -f ${GERRIT_HOME}/oauth.jar ${GERRIT_SITE}/plugins/oauth.jar
    [ -z "${OAUTH_ALLOW_EDIT_FULL_NAME}" ]     || set_gerrit_config oauth.allowEditFullName "${OAUTH_ALLOW_EDIT_FULL_NAME}"
    [ -z "${OAUTH_ALLOW_REGISTER_NEW_EMAIL}" ] || set_gerrit_config oauth.allowRegisterNewEmail "${OAUTH_ALLOW_REGISTER_NEW_EMAIL}"

    # Google
    [ -z "${OAUTH_GOOGLE_RESTRICT_DOMAIN}" ]       || set_gerrit_config plugin.gerrit-oauth-provider-google-oauth.domain "${OAUTH_GOOGLE_RESTRICT_DOMAIN}"
    [ -z "${OAUTH_GOOGLE_CLIENT_ID}" ]             || set_gerrit_config plugin.gerrit-oauth-provider-google-oauth.client-id "${OAUTH_GOOGLE_CLIENT_ID}"
    [ -z "${OAUTH_GOOGLE_CLIENT_SECRET}" ]         || set_gerrit_config plugin.gerrit-oauth-provider-google-oauth.client-secret "${OAUTH_GOOGLE_CLIENT_SECRET}"
    [ -z "${OAUTH_GOOGLE_LINK_OPENID}" ]           || set_gerrit_config plugin.gerrit-oauth-provider-google-oauth.link-to-existing-openid-accounts "${OAUTH_GOOGLE_LINK_OPENID}"
    [ -z "${OAUTH_GOOGLE_USE_EMAIL_AS_USERNAME}" ] || set_gerrit_config plugin.gerrit-oauth-provider-google-oauth.use-email-as-username "${OAUTH_GOOGLE_USE_EMAIL_AS_USERNAME}"

    # Github
    [ -z "${OAUTH_GITHUB_CLIENT_ID}" ]         || set_gerrit_config plugin.gerrit-oauth-provider-github-oauth.client-id "${OAUTH_GITHUB_CLIENT_ID}"
    [ -z "${OAUTH_GITHUB_CLIENT_SECRET}" ]     || set_gerrit_config plugin.gerrit-oauth-provider-github-oauth.client-secret "${OAUTH_GITHUB_CLIENT_SECRET}"

    # GitLab
    [ -z "${OAUTH_GITLAB_ROOT_URL}" ]          || set_gerrit_config plugin.gerrit-oauth-provider-gitlab-oauth.root-url "${OAUTH_GITLAB_ROOT_URL}"
    [ -z "${OAUTH_GITLAB_CLIENT_ID}" ]         || set_gerrit_config plugin.gerrit-oauth-provider-gitlab-oauth.client-id "${OAUTH_GITLAB_CLIENT_ID}"
    [ -z "${OAUTH_GITLAB_CLIENT_SECRET}" ]     || set_gerrit_config plugin.gerrit-oauth-provider-gitlab-oauth.client-secret "${OAUTH_GITLAB_CLIENT_SECRET}"

    # Bitbucket
    [ -z "${OAUTH_BITBUCKET_CLIENT_ID}" ]          || set_gerrit_config plugin.gerrit-oauth-provider-bitbucket-oauth.client-id "${OAUTH_BITBUCKET_CLIENT_ID}"
    [ -z "${OAUTH_BITBUCKET_CLIENT_SECRET}" ]      || set_gerrit_config plugin.gerrit-oauth-provider-bitbucket-oauth.client-secret "${OAUTH_BITBUCKET_CLIENT_SECRET}"
    [ -z "${OAUTH_BITBUCKET_FIX_LEGACY_USER_ID}" ] || set_gerrit_config plugin.gerrit-oauth-provider-bitbucket-oauth.fix-legacy-user-id "${OAUTH_BITBUCKET_FIX_LEGACY_USER_ID}"

    # Keycloak
    [ -z "${OAUTH_KEYCLOAK_CLIENT_ID}" ]     || set_gerrit_config plugin.gerrit-oauth-provider-keycloak-oauth.client-id "${OAUTH_KEYCLOAK_CLIENT_ID}"
    [ -z "${OAUTH_KEYCLOAK_CLIENT_SECRET}" ] || set_gerrit_config plugin.gerrit-oauth-provider-keycloak-oauth.client-secret "${OAUTH_KEYCLOAK_CLIENT_SECRET}"
    [ -z "${OAUTH_KEYCLOAK_REALM}" ]         || set_gerrit_config plugin.gerrit-oauth-provider-keycloak-oauth.realm "${OAUTH_KEYCLOAK_REALM}"
    [ -z "${OAUTH_KEYCLOAK_ROOT_URL}" ]      || set_gerrit_config plugin.gerrit-oauth-provider-keycloak-oauth.root-url "${OAUTH_KEYCLOAK_ROOT_URL}"

    # CAS
    [ -z "${OAUTH_CAS_ROOT_URL}" ]           || set_gerrit_config plugin.gerrit-oauth-provider-cas-oauth.root-url "${OAUTH_CAS_ROOT_URL}"
    [ -z "${OAUTH_CAS_CLIENT_ID}" ]          || set_gerrit_config plugin.gerrit-oauth-provider-cas-oauth.client-id "${OAUTH_CAS_CLIENT_ID}"
    [ -z "${OAUTH_CAS_CLIENT_SECRET}" ]      || set_gerrit_config plugin.gerrit-oauth-provider-cas-oauth.client-secret "${OAUTH_CAS_CLIENT_SECRET}"
    [ -z "${OAUTH_CAS_LINK_OPENID}" ]        || set_gerrit_config plugin.gerrit-oauth-provider-cas-oauth.link-to-existing-openid-accounts "${OAUTH_CAS_LINK_OPENID}"
    [ -z "${OAUTH_CAS_FIX_LEGACY_USER_ID}" ] || set_gerrit_config plugin.gerrit-oauth-provider-cas-oauth.fix-legacy-user-id "${OAUTH_CAS_FIX_LEGACY_USER_ID}"
  fi

  #Section container
  [ -z "${JAVA_HEAPLIMIT}" ] || set_gerrit_config container.heapLimit "${JAVA_HEAPLIMIT}"
  [ -z "${JAVA_OPTIONS}" ]   || set_gerrit_config container.javaOptions "${JAVA_OPTIONS}"
  [ -z "${JAVA_SLAVE}" ]     || set_gerrit_config container.slave "${JAVA_SLAVE}"

  #Section sendemail
  if [ -z "${SMTP_SERVER}" ]; then
    set_gerrit_config sendemail.enable false
  else
    set_gerrit_config sendemail.enable true
    set_gerrit_config sendemail.smtpServer "${SMTP_SERVER}"
    if [ "smtp.gmail.com" = "${SMTP_SERVER}" ]; then
      echo "gmail detected, using default port and encryption"
      set_gerrit_config sendemail.smtpServerPort 587
      set_gerrit_config sendemail.smtpEncryption tls
    fi
    [ -z "${SMTP_SERVER_PORT}" ] || set_gerrit_config sendemail.smtpServerPort "${SMTP_SERVER_PORT}"
    [ -z "${SMTP_USER}" ]        || set_gerrit_config sendemail.smtpUser "${SMTP_USER}"
    [ -z "${SMTP_PASS}" ]        || set_secure_config sendemail.smtpPass "${SMTP_PASS}"
    [ -z "${SMTP_ENCRYPTION}" ]      || set_gerrit_config sendemail.smtpEncryption "${SMTP_ENCRYPTION}"
    [ -z "${SMTP_CONNECT_TIMEOUT}" ] || set_gerrit_config sendemail.connectTimeout "${SMTP_CONNECT_TIMEOUT}"
    [ -z "${SMTP_FROM}" ]            || set_gerrit_config sendemail.from "${SMTP_FROM}"
  fi

  #Section user
    [ -z "${USER_NAME}" ]             || set_gerrit_config user.name "${USER_NAME}"
    [ -z "${USER_EMAIL}" ]            || set_gerrit_config user.email "${USER_EMAIL}"
    [ -z "${USER_ANONYMOUS_COWARD}" ] || set_gerrit_config user.anonymousCoward "${USER_ANONYMOUS_COWARD}"

  #Section plugins
  set_gerrit_config plugins.allowRemoteAdmin true

  #Section plugin events-log
  set_gerrit_config plugin.events-log.storeUrl ${GERRIT_EVENTS_LOG_STOREURL:-"jdbc:h2:${GERRIT_SITE}/db/ChangeEvents"}

  #Section httpd
  [ -z "${HTTPD_LISTENURL}" ] || set_gerrit_config httpd.listenUrl "${HTTPD_LISTENURL}"

  #Section gitweb
  case "$GITWEB_TYPE" in
     "gitiles") su-exec $GERRIT_USER cp -f $GERRIT_HOME/gitiles.jar $GERRIT_SITE/plugins/gitiles.jar ;;
     "") # Gitweb by default
        set_gerrit_config gitweb.cgi "/usr/share/gitweb/gitweb.cgi"
        export GITWEB_TYPE=gitweb
     ;;
  esac
  set_gerrit_config gitweb.type "$GITWEB_TYPE"

  case "${DATABASE_TYPE}" in
    postgresql) [ -z "${DB_PORT_5432_TCP_ADDR}" ]  || wait_for_database ${DB_PORT_5432_TCP_ADDR} ${DB_PORT_5432_TCP_PORT} ;;
    mysql)      [ -z "${DB_PORT_3306_TCP_ADDR}" ]  || wait_for_database ${DB_PORT_3306_TCP_ADDR} ${DB_PORT_3306_TCP_PORT} ;;
    *)          ;;
  esac
  # docker --link is deprecated. All DB_* environment variables will be replaced by DATABASE_* below.
  [ ${#DATABASE_HOSTNAME} -gt 0 ] && [ ${#DATABASE_PORT} -gt 0 ] && wait_for_database ${DATABASE_HOSTNAME} ${DATABASE_PORT}

  echo "Upgrading gerrit..."
  su-exec ${GERRIT_USER} java ${JAVA_OPTIONS} ${JAVA_MEM_OPTIONS} -jar "${GERRIT_WAR}" init --install-all-plugins --batch -d "${GERRIT_SITE}" ${GERRIT_INIT_ARGS}
  if [ $? -eq 0 ]; then
    GERRIT_VERSIONFILE="${GERRIT_SITE}/gerrit_version"

    # MIGRATE_TO_NOTEDB_OFFLINE will override IGNORE_VERSIONCHECK
    if [ -n "${IGNORE_VERSIONCHECK}" ] && [ -z "${MIGRATE_TO_NOTEDB_OFFLINE}" ]; then
      echo "Don't perform a version check and never do a full reindex"
      NEED_REINDEX=0
    else
      # check whether its a good idea to do a full upgrade
      NEED_REINDEX=1
      echo "Checking version file ${GERRIT_VERSIONFILE}"
      if [ -f "${GERRIT_VERSIONFILE}" ]; then
        OLD_GERRIT_VER="V$(cat ${GERRIT_VERSIONFILE})"
        GERRIT_VER="V${GERRIT_VERSION}"
        echo " have old gerrit version ${OLD_GERRIT_VER}"
        if [ "${OLD_GERRIT_VER}" == "${GERRIT_VER}" ]; then
          echo " same gerrit version, no upgrade necessary ${OLD_GERRIT_VER} == ${GERRIT_VER}"
          NEED_REINDEX=0
        else
          echo " gerrit version mismatch #${OLD_GERRIT_VER}# != #${GERRIT_VER}#"
        fi
      else
        echo " gerrit version file does not exist, upgrade necessary"
      fi
    fi
    if [ ${NEED_REINDEX} -eq 1 ]; then
      if [ -n "${MIGRATE_TO_NOTEDB_OFFLINE}" ]; then
        echo "Migrating changes from ReviewDB to NoteDB..."
        su-exec ${GERRIT_USER} java ${JAVA_OPTIONS} ${JAVA_MEM_OPTIONS} -jar "${GERRIT_WAR}" migrate-to-note-db -d "${GERRIT_SITE}"
      else
        echo "Reindexing..."
        su-exec ${GERRIT_USER} java ${JAVA_OPTIONS} ${JAVA_MEM_OPTIONS} -jar "${GERRIT_WAR}" reindex --verbose -d "${GERRIT_SITE}"
      fi
      if [ $? -eq 0 ]; then
        echo "Upgrading is OK. Writing versionfile ${GERRIT_VERSIONFILE}"
        su-exec ${GERRIT_USER} touch "${GERRIT_VERSIONFILE}"
        su-exec ${GERRIT_USER} echo "${GERRIT_VERSION}" > "${GERRIT_VERSIONFILE}"
        echo "${GERRIT_VERSIONFILE} written."
      else
        echo "Upgrading fail!"
      fi
    fi
  else
    echo "Something wrong..."
    cat "${GERRIT_SITE}/logs/error_log"
  fi
fi
exec "$@"
