#!/bin/bash

# ignore secure linux
setenforce Permissive

# create oracle groups
groupadd --gid 54321 oinstall
groupadd --gid 54322 dba
groupadd --gid 54323 oper

# create oracle user
useradd --create-home --gid oinstall --groups oinstall,dba --uid 54321 oracle

# install required OS components
yum install -y oracle-database-server-12cR2-preinstall.x86_64 \
perl \
tar \
unzip \
wget


# environment variables (not configurable when creating a container)
echo "export JAVA_HOME=${JAVA_HOME}" > /.oracle_env
echo "export ORACLE_HOME=${ORACLE_HOME}" >> /.oracle_env
echo "export ORACLE_BASE=${ORACLE_BASE}" >> /.oracle_env
echo "export ORACLE_SID=${ORACLE_SID}" >> /.oracle_env
echo "export PATH=/usr/sbin:\$PATH:/opt/sqlcl/bin" >> /.oracle_env
echo "export PATH=\$ORACLE_HOME/bin:\$PATH" >> /.oracle_env
echo "export LD_LIBRARY_PATH=\$ORACLE_HOME/lib:/lib:/usr/lib" >> /.oracle_env
echo "export CLASSPATH=\$ORACLE_HOME/jlib:\$ORACLE_HOME/rdbms/jlib" >> /.oracle_env
echo "export TMP=/tmp" >> /.oracle_env
echo "export TMPDIR=\$TMP" >> /.oracle_env
echo "export TERM=linux" >> /.oracle_env # avoid in sqlcl: "tput: No value for $TERM and no -T specified"
chmod +x /.oracle_env

# set environment
. /.oracle_env
cat /.oracle_env >> /home/oracle/.bash_profile
cat /.oracle_env >> /root/.bashrc # .bash_profile not executed by docker

# create directories and separate /u01/app/oracle/product to mount ${ORACLE_BASE} as volume
mkdir -p /u01/app/oracle
mkdir -p /u01/app/oracle-product
mkdir -p /u01/app/oraInventory
chown -R oracle:oinstall /u01
ln -s /u01/app/oracle-product /u01/app/oracle/product

# install gosu as workaround for su problems (see http://grokbase.com/t/gg/docker-user/162h4pekwa/docker-su-oracle-su-cannot-open-session-permission-denied)
cp /files/gosu-amd64 /usr/local/bin/gosu
chmod +x /usr/local/bin/gosu

# extract Oracle database software
cd /files
chown oracle:oinstall /files/linuxx64_12201_database.zip
echo "extracting Oracle database software..."
gosu oracle bash -c "unzip -o /files/linuxx64_12201_database.zip -d /files/" > /dev/null
rm -f /files/linuxx64_12201_database.zip

# install Oracle software into ${ORACLE_BASE}
sed -i -E 's:#ORACLE_INVENTORY#:'${ORACLE_INVENTORY}':g' /files/db_install.rsp
sed -i -E 's:#ORACLE_HOME#:'${ORACLE_HOME}':g' /files/db_install.rsp
sed -i -E 's:#ORACLE_BASE#:'${ORACLE_BASE}':g' /files/db_install.rsp

chown oracle:oinstall /files/db_install.rsp
echo "running Oracle installer to install database software only..."
gosu oracle bash -c "/files/database/runInstaller -silent -force -waitforcompletion -responsefile /files/db_install.rsp -ignoresysprereqs -ignoreprereq"

# Run Oracle root scripts
echo "running Oracle root scripts..."
#/u01/app/oraInventory/orainstRoot.sh > /dev/null 2>&1
echo | ${ORACLE_HOME}/root.sh > /dev/null 2>&1 || true

# Delete installer files
rm -fr /files/database

# Creating Database
echo "Creating database. SID: ${ORACLE_SID}"
mv /u01/app/oracle-product/12.2.0.1/dbhome/dbs ${ORACLE_BASE}/dbs
ln -s ${ORACLE_BASE}/dbs /u01/app/oracle-product/12.2.0.1/dbhome/dbs
gosu oracle bash -c "${ORACLE_HOME}/bin/lsnrctl start"
gosu oracle bash -c "${ORACLE_HOME}/bin/dbca -silent -createDatabase -templateName General_Purpose.dbc \
  -gdbname ${SERVICE_NAME} -sid ${ORACLE_SID} -responseFile NO_VALUE -characterSet AL32UTF8 \
-totalMemory $DBCA_TOTAL_MEMORY -emConfiguration DBEXPRESS -sysPassword ${PASS} -systemPassword ${PASS}"
echo "Configure listener."
gosu oracle bash -c 'echo -e "ALTER SYSTEM SET LOCAL_LISTENER='"'"'(ADDRESS = (PROTOCOL = TCP)(HOST = $(hostname))(PORT = 1521))'"'"' SCOPE=BOTH;\n ALTER SYSTEM REGISTER;\n EXIT" | ${ORACLE_HOME}/bin/sqlplus -s -l / as sysdba'
gosu oracle bash -c "${ORACLE_HOME}/bin/lsnrctl stop; ${ORACLE_HOME}/bin/lsnrctl start"

# set some global database settings
gosu oracle bash -c 'echo "ALTER PROFILE DEFAULT LIMIT PASSWORD_LIFE_TIME UNLIMITED;" | ${ORACLE_HOME}/bin/sqlplus -s -l sys/${PASS} AS SYSDBA'