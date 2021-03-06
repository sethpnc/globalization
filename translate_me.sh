#!/bin/bash

#********************************************************************************
# Copyright 2014 IBM
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#********************************************************************************

#############
# Colors    #
#############
export green='\e[0;32m'
export red='\e[0;31m'
export label_color='\e[0;33m'
export no_color='\e[0m' 

################
# Languages    #
################
export lang_en='en'
export lang_all='de,es,fr,it,ja,pt-BR,zh-Hans,zh-Hant'

usage()
{
    echo "Usage: `basename $0` [-s source_pattern] [-o output_directory]"
    echo ""
    echo "Using IBM Globalization Service on Bluemix translates files that match source_pattern" 
    echo ""
    echo "-s        Name of the Source file for translation.  Will look for this filename, if not found will search the directory tree for the file"
    echo "-p        Name of the Globalization project to create"
    echo "-d        Debug mode"
    echo "-h        Displays this usage information"
    echo ""
}

debugme() {
  [[ $DEBUG = 1 ]] && "$@" || :
}

print_limitations() {
    echo -e "${label_color}Current limitations and assumptions:${no_color}"
    echo "  - source pattern will look for files of the format [prefix]_[lang].[type].  For example whateveriwant_en.properties, something_fr.json"
    echo "  - desire all languages translated"
    echo "  - translated files will be placed in the same directory as the source file"
}

wait_for_translation(){
    local project_id=$1
    if [ -z $project_id ]; then 
        echo -e "${red}No project id passed in ${no_color}"
        return 1
    fi 
    local COUNTER=0
    TRANSLATION_STATE="in progress"
    while [[ ( $COUNTER -lt 180 ) && ("${TRANSLATION_STATE}" == "in progress") ]]; do
        let COUNTER=COUNTER+1
        status=$(java -cp "$GAAS_LIB/*" com.ibm.gaas.client.tools.cli.GaasCmd project-info -p ${project_id} -u ${GAAS_ENDPOINT} -k ${GAAS_API_KEY})
        # strip off junk 
        status=${status%*]*}
        debugme echo "${status}"
        status=${status#*translationStatusByLanguage*}
        debugme echo "${status}"
        status=${status#=[*}
        debugme echo "${status}"
        echo ${status} | grep "IN_PROGRESS"
        STILL_WORKING=$?
        if [ $STILL_WORKING -ne 0 ]; then 
            TRANSLATION_STATE="completed"
        else 
            sleep 15
        fi  
        echo "Translation is ${TRANSLATION_STATE}: ${status}"
        echo ""
    done

    if [ "${TRANSLATION_STATE}" == "completed" ]; then 
        return 0
    else
        return 1
    fi 
}

########################
# Process arguments    #
########################

while getopts "s:p:hd" OPTION
do
    case $OPTION in
        s) export INPUT_PATTERN=$OPTARG; echo "set INPUT_PATTERN to ${OPTARG}";;
        p) export SUBMISSION_NAME=$OPTARG; echo "set SUBMISSION_NAME to ${OPTARG}";;
        h) usage; exit 1;;
        d) usage; export DEBUG=1;;
        ?) 
        usage;
        echo "ERROR: Unrecognized option specified.";
        exit 1
    esac
done
shift `expr $OPTIND - 1`
print_limitations

###################
# Check inputs    #
###################
if [ -z $GAAS_ENDPOINT ]; then 
    export GAAS_ENDPOINT="https://gaas.mybluemix.net/translate"
fi 
if [ -z $GAAS_API_KEY ]; then 
    echo -e "${red}API Key for Globalization Service must be set in the environment${no_color}"
    exit 1
fi 
if [ -z $SUBMISSION_NAME ]; then 
    echo -e "${red}SUBMISSION_NAME must be set in the environment${no_color}"
    exit 1
fi 

if [ -z $GAAS_LIB ]; then 
    lib_guess=$(find `pwd` -name gaas-java-client-tools*)
    lib_directory="${lib_guess%/*}"
    if [ -d "${lib_directory}" ]; then 
        export GAAS_LIB="${lib_directory}" 
    else 
        echo -e "${red}GAAS_LIB must be set in the environment${no_color}"
        exit 1
    fi 
fi 
if [ -z $INPUT_PATTERN ]; then 
    echo -e "${red}INPUT_PATTERN is not set${no_color}"
    exit 1
else 
    echo "${INPUT_PATTERN} is the source file pattern"
fi 

####################################
# Create Globalization Project     #
####################################
if [[ $DEBUG -eq 1 ]]; then
    set -x 
fi 

############################################################
# Find and translate all files that match input pattern    #
############################################################
# check if this is a full path 
if [ -f ${INPUT_PATTERN} ]; then 
    echo "found individual file ${INPUT_PATTERN}"
    export source_files="$INPUT_PATTERN"
else 
    echo "searching directory structure for ${INPUT_PATTERN}"
    export source_files=$(find `pwd` -name ${INPUT_PATTERN})
    if [ -z $source_files ]; then 
        echo -e "${red}Could not locate source file that matches ${INPUT_PATTERN} ${no_color}"
        echo -e "${label_color}Directory contents: ${no_color}"
        find . 
        exit 1
    fi 
fi 

COUNT=0
for file in $source_files; do
    cur_dir=`pwd`
    local_file_path="${file##${cur_dir}/}"

    echo "-----------------"
    echo "Processing $local_file_path"
    echo "-----------------" 
    let COUNT+=1
    if [ $COUNT -gt 1 ]; then 
        THIS_SUBMISSION_NAME="${SUBMISSION_NAME}_${COUNT}"
    else 
        THIS_SUBMISSION_NAME=${SUBMISSION_NAME}
    fi 
    directory="${file%/*}"
    debugme echo "directory of resources:$directory"
    filename="${file##/*/}"
    debugme echo "source filename:$filename" 
    extension="${filename##*.}"
    debugme echo "filetype:$extension"
    case $extension in
        'properties') filetype="java";;
        'json') filetype="json";;
        ?) 
        echo -e "${red}Unrecognized file type $extension used";
        exit 1
    esac

    # find the naming pattern  
    prefix="${filename%_*}"
    if [ -z "$prefix" ]; then
        echo -e "${red}Non supported input.  Assuming the input is of type [prefix]_[lang].[type] ${no_color}"
        exit 1 
    fi 
    debugme echo "prefix:${prefix}"
    source_lang="${filename#*_}"
    source_lang="${source_lang%%.*}"
    if [ "${source_lang}" != "en" ]; then 
        echo -e "${red}Currently only supports english as source language and not ${source_lang}${no_color}"
        exit 2
    fi 
    debugme echo "source language:${source_lang}"
    debugme echo "${label_color}Processed files will be placed in ${directory} and will follow naming pattern:${prefix}_[lang].${extension} ${no_color}"

    echo "Creating/checking for IBM Globalization Service project ${THIS_SUBMISSION_NAME}"
    java -cp "$GAAS_LIB/*" com.ibm.gaas.client.tools.cli.GaasCmd create -p ${THIS_SUBMISSION_NAME} -u ${GAAS_ENDPOINT} -k ${GAAS_API_KEY} -s ${source_lang} -l ${lang_all}
    RESULT=$?

    if [ $RESULT -eq 1 ]; then
        echo "..Project has been already created"
    else 
        echo "..Created project"
    fi  
    
    pushd . 
    cd ${directory}
    
    # upload source 
    echo "Uploading ${GAAS_SOURCE_FILE}"
    java -cp "$GAAS_LIB/*" com.ibm.gaas.client.tools.cli.GaasCmd import -f ${file} -l ${source_lang} -t ${filetype} -p ${THIS_SUBMISSION_NAME} -u ${GAAS_ENDPOINT} -k ${GAAS_API_KEY}

    # wait for translation to complete 
    wait_for_translation ${THIS_SUBMISSION_NAME}  

    # download translated files 
    array=(${lang_all//,/ })
    archive_path="${directory##${cur_dir}/}"
    if [ "${archive_path}" == "${cur_dir}" ]; then
        archive_path="."
    fi 

    for i in "${!array[@]}"
    do
        OUTPUT_FILE_NAME="${prefix}_${array[i]}.${extension}"
        echo "Downloading ${array[i]} translated file ${OUTPUT_FILE_NAME} into ${archive_path}"
        java -cp "$GAAS_LIB/*" com.ibm.gaas.client.tools.cli.GaasCmd export -f ${OUTPUT_FILE_NAME} -l ${array[i]} -t ${filetype} -p ${THIS_SUBMISSION_NAME} -u ${GAAS_ENDPOINT} -k ${GAAS_API_KEY}
        RESULT=$? 
        if [ $RESULT -ne 0 ]; then
            echo "Failed"
            exit $RESULT
        fi 
        echo ""
    done
    echo -e "${green}Successfully processed ${local_file_path} ${no_color}"
    popd
done 
# attempt to find it
export GAAS_DASHBOARD=$(cf service "IBM Globalization" | grep Dashboard | awk '{print $2}')
debugme cf services
debugme cf service "IBM Globalization"
if [ -z "$GAAS_DASHBOARD" ]; then 
    echo -e "${label_color}could not locate GaaS Dashboard${no_color}"
    cf services
    cf service "IBM Globalization"
    echo "Using latest cf CLI"
    export GAAS_DASHBOARD=$(${EXT_DIR}/bin/cf service "IBM Globalization" | grep Dashboard | awk '{print $2}')
    debugme ${EXT_DIR}/bin/cf services
    debugme ${EXT_DIR}/bin/cf service "IBM Globalization"

    if [ -z "$GAAS_DASHBOARD" ]; then 
        echo -e "${red}Could not locate dashboard for service IBM Globalization${no_color}"
        export GAAS_DASHBOARD="unknown, please locate the service in your IBM Bluemix dashboard"
    fi 

else
    debugme echo "found GAAS_DASHBOARD :${GAAS_DASHBOARD}"
fi 
echo -e "${label_color}All source files have been placed in the archive of this build, and can be used by additional stages${no_color}"
echo -e "${label_color}All translated files have been put in the same directory as the original source files${no_color}"
echo 
echo -e "A typical continuous delivery scenario uses machine translation as a part of their continuous integration process.  Periodically, the translated messages can be reviewed and updated by translation experts.  This is best done directly within the Globalization Service Dashboard on IBM Bluemix.  Manually applied updates to translated strings will note be overwritten by future build processes unless the source string has also changed."  
echo 
echo -e "The Globalization Dashboard for this organization and space is located at ${green} ${GAAS_DASHBOARD} ${no_color}"

if [[ $DEBUG -eq 1 ]]; then
    set +x 
fi 