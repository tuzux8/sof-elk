#!/bin/bash
# SOF-ELK® Supporting script
# (C)2020 Lewes Technology Consulting, LLC
#
# This script is used to load all dashboards, visualizations, saved searches, and index patterns to Kibana

# set defaults
es_host=localhost
es_port=9200
kibana_host=localhost
kibana_port=5601
kibana_index=.kibana
kibana_file_dir="/usr/local/sof-elk/kibana/"

[ -r /etc/sysconfig/sof-elk ] && . /etc/sysconfig/sof-elk

kibana_version=$( jq -r '.version' < /usr/share/kibana/package.json )
kibana_build=$(jq -r '.build.number' < /usr/share/kibana/package.json )

# enter a holding pattern until the elasticsearch server is available, but don't wait too long
max_wait=60
wait_step=0
interval=5
until curl -s -X GET http://${es_host}:${es_port}/_cluster/health > /dev/null ; do
    wait_step=$(( ${wait_step} + ${interval} ))
    if [ ${wait_step} -gt ${max_wait} ]; then
        echo "ERROR: elasticsearch server not available for more than ${max_wait} seconds."
        exit 5
    fi
    sleep ${interval}
done

# re-insert all ES templates in case anything has changed
# this will not change existing mappings, just new indexes as they are created
# (And why-oh-why isn't this handled by "template_overwrite = true" in the logstash output section?!?!?!?!)
for es_template_file in $( ls -1 /usr/local/sof-elk/lib/elasticsearch-*-template.json ); do
    es_template=$( echo $es_template_file | sed 's/.*elasticsearch-\(.*\)-template.json/\1/' )
    curl -s -H 'kbn-xsrf: true' -H 'Content-Type: application/json' -X PUT http://${es_host}:${es_port}/_template/${es_template} -d @${es_template_file} > /dev/null
done

# set the default index pattern, time zone, and add TZ offset to the default date format, and other custom Kibana settings
curl -s -H 'kbn-xsrf: true' -H 'Content-Type: application/json' -X POST http://${es_host}:${es_port}/${kibana_index}/_doc/config:${kibana_version} -d @${kibana_file_dir}/sof-elk_config.json > /dev/null

# increase the recovery priority for the kibana index so we don't have to wait to use it upon recovery
curl -s -H 'kbn-xsrf: true' -H 'Content-Type: application/json' -X PUT http://${es_host}:${es_port}/${kibana_index}/_settings -d "{ \"settings\": {\"index\": {\"priority\": 100 }}}" > /dev/null

# insert/update dashboards, visualizations, maps, and searches
TMPNDJSONFILE=$( mktemp --suffix=.ndjson )
cat ${kibana_file_dir}/dashboard/*.json ${kibana_file_dir}/visualization/*.json ${kibana_file_dir}/map/*.json ${kibana_file_dir}/search/*.json | jq -c '.' > ${TMPNDJSONFILE}
curl -s -H 'kbn-xsrf: true' --form file=@${TMPNDJSONFILE} -X POST "http://${kibana_host}:${kibana_port}/api/saved_objects/_import?overwrite=true" > /dev/null
rm -f ${TMPNDJSONFILE}

# replace index patterns
for indexpatternfile in ${kibana_file_dir}/index-pattern/*.json; do
    INDEXPATTERNID=$( basename ${indexpatternfile} | sed -e 's/\.json$//' )

    # reconstruct the new index-pattern with the proper fields and fieldFormatMap values
    if [ -f ${kibana_file_dir}/index-pattern/fields/${INDEXPATTERNID}.json ]; then
        fields=1
    else
        fields=0
    fi
    if [ -f ${kibana_file_dir}/index-pattern/fieldformats/${INDEXPATTERNID}.json ]; then
        fieldformatmap=1
    else
        fieldformatmap=0
    fi

    # create a temp file to hold the reconstructed index-pattern
    TMPNDJSONFILE=$( mktemp --suffix=.ndjson )

    if [ ${fieldformatmap} == 1 ]; then
        cat ${indexpatternfile} | jq -c --arg fields "$( cat ${kibana_file_dir}/index-pattern/fields/${INDEXPATTERNID}.json | jq -sc '.' )" --arg fieldformatmap "$( cat ${kibana_file_dir}/index-pattern/fieldformats/${INDEXPATTERNID}.json | jq -c 'from_entries' )" '.attributes += { fields: $fields, fieldFormatMap: $fieldformatmap }' > ${TMPNDJSONFILE}
    else
        cat ${indexpatternfile} | jq -c --arg fields "$( cat ${kibana_file_dir}/index-pattern/fields/${INDEXPATTERNID}.json | jq -sc '.' )" '.attributes += { fields: $fields }' > ${TMPNDJSONFILE}
    fi

    # update the index-mapping object
    curl -s -H 'kbn-xsrf: true' --form file=@${TMPNDJSONFILE} -X POST "http://${kibana_host}:${kibana_port}/api/saved_objects/_import?overwrite=true" > /dev/null

    # remove the temp file
    rm -f ${TMPNDJSONFILE}
done