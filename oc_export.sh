#!/bin/bash

OPENSHIFT_URL=$(minishift console --url)

function help() {
  echo "Example usage:"
  echo "  oc_export.sh --all --password-file ./my-password.txt"
  echo "  oc_export.sh --configmap --deployment --yes"
  echo "  oc_export.sh -a -y -f password.txt"
}

oc_export() {
  TYPE="$1"

  ITEMS=$( oc get ${TYPE} --no-headers -o custom-columns=NAME:.metadata.name )

  while read ITEM;
  do
    if [ "$ITEM" != "" ]
    then
      mkdir -p "${OUTPUT_DIR}/openshift/${REGION}/${TYPE}s/"
      oc get ${TYPE} --export -o yaml ${ITEM} > "${OUTPUT_DIR}/openshift/${REGION}/${TYPE}s/${ITEM}.yml" 2>/dev/null

      # if file has size > 0
      if [ -s "${OUTPUT_DIR}/openshift/${REGION}/${TYPE}s/${ITEM}.yml" ]
      then
        echo "Exported ${TYPE}: ${ITEM}"
      else
        rm -f "${OUTPUT_DIR}/openshift/${REGION}/${TYPE}s/${ITEM}.yml"
      fi

    fi
  done <<< "${ITEMS}"
}

export_region() {
  REGION="$1"
  if [ "$REGION" == "" ]
  then
    echo "REGION is not defined. Exiting"
    exit 1
  fi

  if [ "$SERVICE" ] || [ "$ALL" ]
  then
    oc_export service
  fi
  
  if [ "$ROUTE" ] || [ "$ALL" ]
  then
    oc_export route
  fi
  
  if [ "$DEPLOYMENT" ] || [ "$ALL" ]
  then
    oc_export deployment
  fi
  
  if [ "$CONFIGMAP" ] || [ "$ALL" ]
  then
    oc_export configmap
  fi
  
  if [ "$SECRET" ] || [ "$ALL" ]
  then
    oc_export secret
  fi

  echo "Export finished for all region: $REGION"
}

handle_secrets() {
  SECRETS_DIR="$1"
  ACTION="$2"
  if [ ! -d "$SECRETS_DIR" ]
  then
    echo "No secrets directory found in: $(dirname ${SECRETS_DIR})"
    return
  fi

  if [[ ! "$ACTION" =~ ^(decrypt|encrypt) ]]
  then
    echo "Second paramter passed must be 'encrypt' or 'decrypt'"
    exit 1
  fi

  if [ ! -f "$PASSWORD_FILE" ]
  then
    echo "No password file found."
    exit 1
  fi

  ansible-vault "$ACTION" --vault-password-file "$PASSWORD_FILE" $SECRETS_DIR/*
  echo "Successfully ${ACTION}ed $SECRETS_DIR"
}

deduplicate_yaml_files() {
  echo "Checking for duplicate files in regions and moving to 'all'"
  REGION_A_FILES=$(find ${OUTPUT_DIR}/openshift/region-a/ -type f)

  while read -r FILE
  do
    REGION_B_FILE="$( echo $FILE | sed s/region-a/region-b/ )"
    if [ -f "$REGION_B_FILE" ]
    then
      A_SHA=$( cat $FILE | sha256sum )
      B_SHA=$( cat $REGION_B_FILE | sha256sum )

      if [ "$A_SHA" == "$B_SHA" ]
      then
        echo "SHA-256 sum match on $FILE with region-b. Moving to 'all'"
        ALL_FILE="$( echo $FILE | sed s/region-a/all/ )"
        # ensure equivalent 'all' dir exists
        mkdir -p $( dirname "$ALL_FILE" )
        cp -f $FILE $ALL_FILE
        rm -f $FILE $REGION_B_FILE

      fi
    fi
  done <<< "${REGION_A_FILES}"

  echo "Deleting any empty directories"
  find ${OUTPUT_DIR} -type d -empty -delete
}

login() {
  URL="$1"
  USERNAME=$(oc whoami 2>/dev/null)
  if [ "$USERNAME" ]
  then
    CURRENT_URL="$( oc status | grep -E 'In project.+on server.+' | grep -Po 'http.+' )"
    if [ "$CURRENT_URL" == "$URL" ]
    then
      echo "Already logged into correct region."
      return
    else
      oc logout
      USERNAME=""
    fi
  fi

  if [ "$USERNAME" = "" ]
  then
    oc login ${URL} || exit 1
  fi

  oc project "$PROJECT" || exit 1
  export TOKEN=$(oc whoami -t)
}


# : = mandatory, :: = option with a default
# -o = short options, -l = long options
args=$(getopt -o "hyp:asrdckf:o:" -l "help,yes,project:,all,service,route,deployment,configmap,secret,password-file:,output-dir:" -- "$@")
eval set -- "$args"

PROJECT=""
YES=""
ALL=""
SERVICE=""
ROUTE=""
DEPLOYMENT=""
CONFIGMAP=""
SECRET=""
PASSWORD_FILE=""
OUTPUT_DIR=""
TYPE_SELECTED=""

while [ $# -ge 1 ];
do
  case "$1" in
    --)
      shift
      break ;;
    -h|--help)
      help
      exit 0 ;;
    -y|--yes)
      YES="true" ;;
    -p|--project)
      if [ "$2" == "" ] || [ "$2" == "--" ]
      then
        echo "Project name not specified. Exiting."
        exit 1
      fi

      PROJECT="$2" 
      shift ;;
    -a|--all)
      TYPE_SELECTED="true"
      ALL="true" ;;
    -s|--service)
      TYPE_SELECTED="true"
      SERVICE="true" ;;
    -r|--route)
      TYPE_SELECTED="true"
      ROUTE="true" ;;
    -d|--deployment)
      TYPE_SELECTED="true"
      DEPLOYMENT="true" ;;
    -c|--configmap)
      TYPE_SELECTED="true"
      CONFIGMAP="true" ;;
    -k|--secret)
      TYPE_SELECTED="true"
      SECRET="true" ;;
    -f|--password-file)
      PASSWORD_FILE="$2"
      shift ;;
    -o|--output-dir)
      if [ -d "$2" ]
      then
        OUTPUT_DIR="$2"
      else
        echo "Output directory not specified or does not exist"
        exit 1
      fi
      shift ;;
    *)
      echo "An error occurred"
      help
      exit 1 ;;
  esac
  shift
done

if [ ! "$OUTPUT_DIR" ]
then
  OUTPUT_DIR="./${PROJECT}"
fi

if [ ! "$PROJECT" ]
then
  echo "You must specify an Openshift project to export using the '-p' command line options"
  exit 1
fi

if [ "$TYPE_SELECTED" == "" ]
then
  echo "You have no specified anything to export. Exiting"
  exit 1
fi

if [ "$ALL" ]
then
  SERVICE="true"
  ROUTE="true"
  DEPLOYMENT="true"
  CONFIGMAP="true"
  SECRET="true"
fi

if [ "$SECRET" ]
then
  GENERATE_PASSWORD="true"
  if [ "$PASSWORD_FILE" ]
  then
    if [ ! "$(cat ${PASSWORD_FILE} 2> /dev/null)" ]
    then
      read -p "Specified password file does not exist or is empty. Do you want to generate it? [y/N] " -n 1 -r
      echo
      if [[ ! "$REPLY" =~ ^[Yy]$ ]]
      then
        echo "Exiting"
        exit 1
      fi
    else
      GENERATE_PASSWORD=""
    fi
  else
    read -p "Password file to use not specified. If you want to specify one please press Ctrl+C, otherwise one will be generated for you. Do you want generate one? [y/N] " -n 1 -r
    echo
    if [[ ! "$REPLY" =~ ^[Yy]$ ]]
    then
      echo "Exiting"
      exit 0
    fi
  fi

  if [ "$GENERATE_PASSWORD" ]
  then
    PASSWORD_FILE=${PASSWORD_FILE:-./password.txt}
   
    # Check if password file exists and ok to overwrite
    if [ -f "$PASSWORD_FILE" ]
    then
      read -p "Password file $PASSWORD_FILE already exists! Do you want to overwrite it? [y/N] " -n 1 -r
      echo
      if [[ ! "$REPLY" =~ ^[Yy]$ ]]
      then
        echo "Exiting"
        exit 0
      fi
      
    fi
    echo "Generating password and storing in ${PASSWORD_FILE}"
    echo "$(uuidgen -r)" > "${PASSWORD_FILE}"
  fi
fi

echo "Running with config:"
echo "  Project: $PROJECT"
echo "  Password file: $PASSWORD_FILE"
echo "  Output directory: $OUTPUT_DIR"
echo "  All: $ALL"
echo "  Service: $SERVICE"
echo "  Route: $ROUTE"
echo "  Deployment: $DEPLOYMENT"
echo "  Configmap: $CONFIGMAP"
echo "  Secret: $SECRET"

if [ "$YES" != "true" ]
then
  read -p "Do you wish to continue? [y/N] " -n 1 -r
  echo
  if [[ ! "$REPLY" =~ ^[Yy]$ ]]
  then
    echo "Exiting"
    exit 0
  fi
fi




# Log into OpenShift
login $(minishift console --url | grep -Po "192.168.+:8443")

PROJECT_EXISTS=$( oc projects -q | grep "^${PROJECT}$" | wc -l )
if [ "${PROJECT_EXISTS}" -eq 0 ]
then
  echo "Cannot find a project called $PROJECT to switch to."
  exit 1
fi

# decrypt all secrets
handle_secrets "${OUTPUT_DIR}/openshift/all/secrets/" "decrypt"
handle_secrets "${OUTPUT_DIR}/openshift/region-a/secrets/" "decrypt"
handle_secrets "${OUTPUT_DIR}/openshift/region-b/secrets/" "decrypt"

export_region "region-a"

# log into region b
export_region "region-b"

deduplicate_yaml_files

# encrypt all secrets
handle_secrets "${OUTPUT_DIR}/openshift/all/secrets/" "encrypt"
handle_secrets "${OUTPUT_DIR}/openshift/region-a/secrets/" "encrypt"
handle_secrets "${OUTPUT_DIR}/openshift/region-b/secrets/" "encrypt"

echo "Export finished"