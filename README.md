This launches the OpenBIS container from DockerHub, together with the Postgres database and a landing page with links to the ELN and the Admin interface of OpenBIS.

It uses the ingress of an existing kubernetes cluster for mapping domain names to port numbers of the containers.

## in the container:

find / -name '*keystore*' 2>/dev/null
/etc/openbis/dss/openBIS.keystore
/etc/openbis/as/openBIS.keystore
/etc/ca-certificates/update.d/jks-keystore
/home/openbis/servers/openBIS-server/jetty/etc.default/openBIS.keystore
/home/openbis/servers/openBIS-server/jetty-dist/modules/ssl/keystore
/home/openbis/servers/openBIS-server/jetty-dist/demo-base/etc/keystore
/home/openbis/servers/datastore_server/etc.default/openBIS.keystore

Somehow, the key from website needs to be added to the keystore for java not to complain:

keytool -import -alias <server_alias> -file <server_cert.cer> -keystore <JAVA_HOME>/lib/security/cacerts -storepass changeit

PEM files need to be converted first:

openssl pkcs12 -export -in chain.pem -out chain.p12 -name "mycert"

keytool -importkeystore -destkeystore truststore.jks -srckeystore chain.p12 -srcstoretype PKCS12 -alias mycert

(https://www.perplexity.ai/search/for-openbis-server-side-logs-h-YhMrzCisQduUnVHmP73a1Q)
