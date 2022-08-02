#! /bin/bash

GOOGLE_CLOUD_BUCKET=website-v3-content
GOOGLE_CLOUD_PROJECT=digital-ucdavis-edu
UPLOADS_TAR_FILE=uploads.tar.gz
UPLOADS_DIR=/uploads
MYSQL_DUMP_FILE=main-wp-website.sql.gz
WP_SERVER_URL=${SERVER_URL:-http://localhost:3000}

shopt -s expand_aliases

# separate db host from port. wp conflates them in its host config variable.
if [[ $WORDPRESS_DB_HOST =~ ":" ]]; then
	WORDPRESS_DB_JUST_HOST=$(echo $WORDPRESS_DB_HOST | cut -d ":" -f1)
  WORDPRESS_DB_JUST_PORT=$(echo $WORDPRESS_DB_HOST | cut -d ":" -f2)
else
  WORDPRESS_DB_JUST_HOST=$WORDPRESS_DB_HOST
  WORDPRESS_DB_JUST_PORT=3306
fi
alias mysql="mysql --user=$WORDPRESS_DB_USER --host=$WORDPRESS_DB_JUST_HOST --port=$WORDPRESS_DB_JUST_PORT --password=$WORDPRESS_DB_PASSWORD $WORDPRESS_DB_DATABASE"

# wait for db to start up
wait-for-it $WORDPRESS_DB_JUST_HOST:$WORDPRESS_DB_JUST_PORT -t 0

if [[ -z "$RUN_INIT" || -z "$DATA_ENV" ]]; then
  echo "Skipping db and media uploads hydration.";
  if [[ -z "$RUN_INIT" ]]; then
		echo "No RUN_INIT flag found."
  else 
		echo "DATA_ENV environmental variable is not set."
  fi
else
	
  # check database
	
  DB_HAS_DATA=$(echo "SELECT count(*) FROM information_schema.TABLES WHERE (TABLE_SCHEMA = '${WORDPRESS_DB_DATABASE}') AND (TABLE_NAME = 'wp_options')" | mysql -s )
  if [[ $DB_HAS_DATA = 0 ]]; then
		echo "No WP data found in db, attempting to pull content for google cloud bucket"
		
		gcloud auth login --quiet --cred-file=${GOOGLE_APPLICATION_CREDENTIALS}
		gcloud config set project $GOOGLE_CLOUD_PROJECT
		
		echo "Downloading: gs://${GOOGLE_CLOUD_BUCKET}/${DATA_ENV}/${MYSQL_DUMP_FILE}"
		gsutil cp "gs://${GOOGLE_CLOUD_BUCKET}/${DATA_ENV}/${MYSQL_DUMP_FILE}" /$MYSQL_DUMP_FILE

    echo "Loading sql dump file"
    zcat /$MYSQL_DUMP_FILE | mysql -f
    rm /$MYSQL_DUMP_FILE
  else
    echo "WP data found in ${WORDPRESS_DB_JUST_HOST}:${WORDPRESS_DB_JUST_PORT}. Skipping hydration."
  fi

  BACKUP_SERVER_URL=$(echo "SELECT option_value from wp_options WHERE option_name='siteurl' LIMIT 1" | mysql -s)

  if [[ ${BACKUP_SERVER_URL} != ${WP_SERVER_URL} ]]; then
    echo "Updating links from ${BACKUP_SERVER_URL} to ${WP_SERVER_URL}"
    
    # WP options
    mysql -e "update wp_options set option_value='${WP_SERVER_URL}' where option_name='siteurl';"
    mysql -e "update wp_options set option_value='${WP_SERVER_URL}' where option_name='home';"
    # First fix objects
    for obj in $(mysql -s -e "select option_name from wp_options where option_value like 'a:%' and option_value like '%${BACKUP_SERVER_URL}%'"); do
			new=$(wp --allow-root option --format=json get ${obj} | sed -e "s|${BACKUP_SERVER_URL}|${WP_SERVER_URL}|g")
			wp --allow-root option update ${obj} "${new}" --format=json
    done
    # Then text
    mysql -e "UPDATE wp_options SET option_value = REPLACE(option_value, '${BACKUP_SERVER_URL}', '${WP_SERVER_URL}');"
    
    # POSTS
    mysql -e "UPDATE wp_posts SET post_content = REPLACE(post_content, '${BACKUP_SERVER_URL}', '${WP_SERVER_URL}');"
    mysql -e "UPDATE wp_posts SET guid = REPLACE(guid, '${BACKUP_SERVER_URL}', '${WP_SERVER_URL}');"
    
    # wp_postmeta
    # First fix objects
    for obj in $(mysql -s -e "select concat(post_id,':',meta_key) from wp_postmeta where meta_value like 'a:%' and meta_value like '%${BACKUP_SERVER_URL}%'"); do
			post_id=${obj%:*}; meta_key=${obj#*:};
			new=$(wp --allow-root post meta --format=json get ${post_id} ${meta_key} | sed -e "s|${BACKUP_SERVER_URL}|${WP_SERVER_URL}|g")
			wp --allow-root post meta update ${post_id} ${meta_key} "${new}" --format=json
    done
    # Then text
    mysql -e "UPDATE wp_postmeta SET meta_value = REPLACE(meta_value, '${BACKUP_SERVER_URL}', '${WP_SERVER_URL}');"
  else
    echo "${BACKUP_SERVER_URL}=${WP_SERVER_URL} so skipping db updates"
  fi
  
  if [[ ! -z $SITE_TAGLINE ]]; then
    mysql -e "update wp_options set option_value='${SITE_TAGLINE}' where option_name='blogdescription';"
  fi

  echo "Starting full elastic search reindex"
  curl http://indexer:3000/reindex

  # check uploads folder
  UPLOADS_FILE_COUNT=$(ls -1q $UPLOADS_DIR | wc -l)

  if [[ $UPLOADS_FILE_COUNT == 0 ]]; then
    echo "Uploads folder is empty, attempting to pull content for google cloud bucket"
		
    # WHY??? 
    gcloud auth login --quiet --cred-file=${GOOGLE_APPLICATION_CREDENTIALS}
    gcloud config set project $GOOGLE_CLOUD_PROJECT

    echo "Downloading: gs://${GOOGLE_CLOUD_BUCKET}/${DATA_ENV}/${UPLOADS_TAR_FILE}"
    gsutil cp "gs://${GOOGLE_CLOUD_BUCKET}/${DATA_ENV}/${UPLOADS_TAR_FILE}" $UPLOADS_DIR/$UPLOADS_TAR_FILE
    echo "Extracting: tar -zxvf $UPLOADS_DIR/$UPLOADS_TAR_FILE -C $UPLOADS_DIR"
    cd $UPLOADS_DIR
    tar -zxvf $UPLOADS_DIR/$UPLOADS_TAR_FILE -C .
    rm $UPLOADS_DIR/$UPLOADS_TAR_FILE

    # Check if zip file contained a 'uploads' folder, if so move up one directory
    UPLOADS_FILE_COUNT=$(ls -1q $UPLOADS_DIR | wc -l)
    FILE_NAME=$(ls -1q)
    if [[ $UPLOADS_FILE_COUNT == 1 && $FILE_NAME == 'uploads' ]]; then
      mv uploads/* .
      rm -r uploads
    fi
  else
    echo "Uploads folder has data. Skipping hydration."
  fi

fi

echo "Init container is finished and exiting (this is supposed to happen)"
