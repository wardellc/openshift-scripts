#!/bin/bash


help() {
  echo "Example usage:"
}

print_openshift_dir_help() {
  echo "'./openshift' directory not found in current directory."
  echo "Openshift deployment files should be placed in here within a directory that follows the appropriate structure."
  echo "For example:"
  echo "  ./openshift/"
  echo "             /region-a/"
  echo "                      /all/"
  echo "                          /services/"
  echo "                          /configmaps/"
  echo "                      /dev/"
  echo "                          /deployments/"
  echo "                          /secrets/"
  echo "                      /live/"
  echo "                           /deployments/"
  echo "                           /secrets/"
  echo "             /region-b/"
  echo "                      /all/"
  echo "                          /services/"
  echo "                          /configmaps/"
  echo "                      /dev/"
  echo "                          /deployments/"
  echo "                          /secrets/"
  echo "                      /live/"
  echo "                           /deployments/"
  echo "                           /secrets/"
  echo "Split configuration files by region, then environment then by config type."
  echo "This script will deploy anyting in the 'all' environment as well as the environment you specify. E.g. 'dev'"
  echo "This means if you have some environment-agnostic config, you can put it in here"
  echo "This script will automatically decrypt, with the provided password file, any files in the 'secrets' directory, deploy them and then re-encrypt them after."
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
}

get_version_tag() {
  LATEST_TAG="$(git tag -l | grep -E "[0-9]+\.[0-9]+\.[0-9]+" | tail -1)"
  GIT_BRANCH="$(git branch | grep '*')"

  # on tagged branch, use the tag
  TAGGED_BRANCH=$( echo "${GIT_BRANCH}" | grep -E "\* \(detached from [0-9]+\.[0-9]+\.[0-9]+\)" | wc -l)
  if [ "${TAGGED_BRANCH}" == "1" ]
  then
    echo "$( git branch | grep -Po '[0-9]+\.[0-9]+\.[0-9]+')"
    exit 0
  # on master branch, use incremented minor version or 1.0.0
  elif [[ "${GIT_BRANCH}" =~ "* master" ]]
  then
    # if no latest tag then must be first tag, otherwise increment version
    if [ "${LATEST_TAG}" == "" ]
    then
      echo "1.0.0"
      exit 0
    else
      MAJOR=$(echo ${LATEST_TAG} | cut -d"." -f1)
      MINOR=$(echo ${LATEST_TAG} | cut -d"." -f2)
      BUG=$(echo ${LATEST_TAG} | cut -d"." -f3)

      # increment minor version number and reset bug version to 0
      MINOR="$((MINOR + 1))"
      echo "${MAJOR}.${MINOR}.0"
      exit 0
    fi
  # not on tagged branch or master, use latest
  else
    echo "latest"
    exit 0
  fi
}

build_images() {
  while read BUILD_DIR;
  do
    echo "Current build directory: $BUILD_DIR"   

    IMAGE_TAG=$( basename ${BUILD_DIR} )
    if [ -f "${BUILD_DIR}/Dockerfile.${ENVIRONMENT}" ]
    then
      echo "Building '${BASE_TAG}-${IMAGE_TAG}' from '${BUILD_DIR}/Dockerfile.${ENVIRONMENT}'"
      #podman build -t "${BASE_TAG}-${IMAGE_TAG}:${VERSION_TAG}" -f "${BUILD_DIR}/Dockerfile.${ENVIRONMENT}" | grep "^STEP [0-9]+:"
      podman build -t "${BASE_TAG}-${IMAGE_TAG}:${VERSION_TAG}" -f "${BUILD_DIR}/Dockerfile.${ENVIRONMENT}"
    elif [ -f "${BUILD_DIR}/Dockerfile" ]
    then
      echo "Building '${BASE_TAG}-${IMAGE_TAG}' from '${BUILD_DIR}/Dockerfile"
      #podman build -t "${BASE_TAG}-${IMAGE_TAG}:${VERSION_TAG}" -f "${BUILD_DIR}/Dockerfile" --build-arg="ENV=${ENVIRONMENT}" | grep "^STEP [0-9]+:"
      podman build -t "${BASE_TAG}-${IMAGE_TAG}:${VERSION_TAG}" -f "${BUILD_DIR}/Dockerfile" --build-arg="ENV=${ENVIRONMENT}"
    fi
  done <<< "$BUILD_DIRS"
}

upload_images() {
  REGION_DIRS="$( find ./openshift/ -maxdepth 1 -mindepth 1 -type d )"
  # push to all regions
  while read REGION_RAW
  do
    REGION="$(basename $REGION_RAW)"
    while read BUILD_DIR;
    do
      # login ....$REGION....
      login "$( echo ${OPENSHIFT_URL} | grep -Po '192.168.+:8443' )"
      IMAGE_TAG=$( basename ${BUILD_DIR} )
      echo "Pushing '${BASE_TAG}-${IMAGE_TAG}:${VERSION_TAG}' to ${OPENSHIFT_URL}"
      # skopeo.... ${BASE_TAG}-${IMAGE_TAG}:${VERSION_TAG}  ${OPENSHIFT_URL}/${BASE_TAG}-${IMAGE_TAG}:${VERSION_TAG}
    done <<< "$BUILD_DIRS"
  done <<< "$REGION_DIRS"
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
    oc login ${URL} --insecure-skip-tls-verify=true || exit 1
  fi

  oc project "$PROJECT" || exit 1
  export TOKEN=$(oc whoami -t)
}

deploy_openshift_config() {
  if [ ! -d "./openshift" ]
  then
    print_openshift_dir_help
    exit 1
  else
    REGION_DIRS="$( find ./openshift/ -maxdepth 1 -mindepth 1 -type d )"
    while read REGION_RAW
    do
      REGION=$(basename $REGION_RAW)
      if [[ ! "$REGION" =~ region-[a-z]$ ]]
      then
        echo "Region '$(basename ${REGION})' is not valid. Must be 'region-X' where X is a lowercase letter"
        exit 1
      fi
    
      # TODO log into that region and select project
    
      if [ -d "./openshift/${REGION}/all/" ]
      then
        echo "'all' environment found in ${REGION}"
        handle_secrets "./openshift/$REGION/all/secrets/" "decrypt"
        oc apply -R -f "./openshift/$REGION/all/"
        encrypt_secrets "./openshift/$REGION/all/secrets/" "encrypt"
      fi
      
      if [ -d "./openshift/${REGION}/${ENVIRONMENT}/" ]
      then
        echo "'${ENVIRONMENT}' environment found in ${REGION}"
        handle_secrets "./openshift/$REGION/${ENVIRONMENT}/secrets/" "decrypt"
        oc apply -R -f "./openshift/$REGION/${ENVIRONMENT}/"
        encrypt_secrets "./openshift/$REGION/${ENVIRONMENT}/secrets/" "encrypt"
      fi
    done <<< "$REGION_DIRS"
  fi

}

parse_command_line_arguments() {
  # : = mandatory, :: = option with a default
  # -o = short options, -l = long options
  args=$(getopt -o "hpe:k:" -l "help,project,environment:,password-file:" -- "$@")
  eval set -- "$args"

  while [ $# -ge 1 ];
  do
    case "$1" in
      --)
        shift
        break ;;
      -h|--help)
        help
        exit 0 ;;
      -p|--project)
        PROJECT_EXISTS=$( oc projects | grep "$2" )
        if [ ${PROJECT_EXISTS} -gt 0 ]
        then
          oc project "$2"
          PROJECT="$2"
          shift
        else
          echo "Cannot find a project called $2 to switch to."
          exit 1
        fi ;;
      -e|--environment)
        if [[ ! "$2" =~ [0-9a-zA-Z_-]+ ]]
        then
          echo "Invalid environment specified. Must be alphanumeric, lowercase or uppercase and can contain hyphens and underscores"
          exit 1
        fi
        ENVIRONMENT="$2"
        shift ;;
      -k|--password-file)
        if [ ! -f "$2" ]
        then
          echo "Password file not found: $2"
          exit 1
        fi
        PASSWORD_FILE="$2"
        shift ;;
      *)
        echo "An error occurred"
        help
        exit 1 ;;
    esac
    shift
  done

}

# Log into OpenShift
OPENSHIFT_URL=$(minishift console --url)
login $( echo ${OPENSHIFT_URL}  | grep -Po 192.168.+:8443 )
PROJECT="$( oc project -q )"
ENVIRONMENT="dev"
PASSWORD_FILE=""

# set password file for ansible vault if it exists
if [ -f "$HOME/password_files/$ENVIRONMENT/$(basename `pwd`).txt" ]
then
  echo "Password file found"
  PASSWORD_FILE=$HOME/password_files/$ENVIRONMENT/$(basename `pwd`).txt
  chmod 400 "$PASSWORD_FILE"
fi

parse_command_line_arguments

if [ ! -d "./docker-builds" ]
then
  echo "'./docker-builds' directory not found in current directory."
  echo "Images to be built should be placed in here within a directory which is appropriately named after the image."
  echo "For example: ./docker-builds/nginx/Dockerfile"
  echo "Exiting."
  exit 1
fi

BUILD_DIRS="$( find ./docker-builds/ -maxdepth 1 -mindepth 1 -type d )"
BASE_TAG="$( basename `pwd` | sed s/service[-_]// | sed s/_/-/g )"
VERSION_TAG="$(get_version_tag)"

echo "Environment: ${ENVIRONMENT}"
echo "Version tag: ${VERSION_TAG}"
echo "Password file: ${PASSWORD_FILE}"

build_images
upload_images
deploy_openshift_config