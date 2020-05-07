#!/usr/bin/env bash
set -e

install_jq(){
  OS=$( uname )
  if [ ${OS} = "Linux" ]; then
    sudo add-apt-repository universe >/dev/null 2>&1
    sudo apt-get update > /dev/null 2>&1
    sudo apt-get install -y jq > /dev/null 2>&1 || { echo "JQ install failed Please email to contact@apptest.ai"; exit 256;}
  elif [ ${OS} = "Darwin" ]; then
    brew install jq > /dev/null 2>&1 || { echo "jq install failed please email to contact@apptest.ai"; exit 256; }
  else
    echo "Unknown OS name : ${OS} please contact contact@apptest.ai "
    exit 256
  fi
}

access_key=${APPTEST_AI_ACCESS_KEY}

if [ -z "${binary_path}" ]; then
  echo "Test app's binary path is needed"
  exit 255
fi

if [ -z "${project_id}" ]; then
  echo "apptest.ai project id is needed"
  exit 254
fi

if [ -z "${access_key}" ]; then
  echo "apptest.ai access key should be set as APPTEST_AI_ACCESS_KEY"
  exit 253
fi

if [ -z "${waiting_for_test_results}" ]; then
  waiting_for_test_results="true"
fi
         
if [ -z "${test_result_path}" ]; then
  test_result_path="test-results"
fi

if [ ! -f "${binary_path}" ]; then
  echo "Can't find binary file at ${binary_path}"
  exit 252
fi

if [ -z "${use_vo}" ]; then
  use_vo="false"
fi

if [ -z "${testset_name}" ]; then
  COMMIT_MESSAGE=$(git log --format=%B -n 1 $CIRCLE_SHA1)
  testset_name="circleci - ${COMMIT_MESSAGE}"
fi

testset_name_len=${#testset_name}
if [ $testset_name_len -gt 99 ]; then
  testset_name=$(echo ${testset_name} | cut -c1-99)
fi

jq --version > /dev/null 2>&1 || install_jq 

#apk_file_d='apk_file=@'\"${binary_path}\"
#data_d='data={"pid":'${project_id}',"test_set_name":"circleci"}'
app_file_d="app_file=@\"${binary_path}\""

data_d="data={\"pid\": ${project_id}"
data_d="${data_d}, \"testset_name\": \"${testset_name}\""
if [ ! -z "$time_limit" ]; then
  if [[ $time_limit -gt 4 && $time_limit -lt 31 ]]; then
    data_d="${data_d}, \"time_limit\": ${time_limit}"
  fi
fi
data_d="${data_d}, \"use_vo\": ${use_vo}"
if [ ! -z "$callback" ]; then
  data_d="${data_d}, \"callback\": \"${callback}\""
fi
if [[ ! -z "${login_id}" && ! -z "${login_pw}" ]]; then
  data_d="${data_d}, \"credentials\": { \"login_id\": \"${login_id}\", \"login_pw\": \"${login_pw}\"}"
fi
data_d="${data_d}}"

testRunUrl="https://api.apptest.ai/openapi/v2/testset"
HTTP_RESPONSE=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" -F "${app_file_d}" -F "${data_d}" --user ${access_key} ${testRunUrl})

HTTP_BODY=$(echo "${HTTP_RESPONSE}" | sed -e 's/HTTPSTATUS\:.*//g')
HTTP_STATUS=$(echo "${HTTP_RESPONSE}" | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')

if [ ! ${HTTP_STATUS} -eq 200  ]; then
  echo "Error [HTTP status: ${HTTP_STATUS}]"
  exit 251
fi

create_test_result=$(echo "${HTTP_BODY}" | jq -r .result)
if [ ${create_test_result} == 'fail' ]; then
  echo "apptest.ai Test Run Fail :" $(echo ${HTTP_BODY} | jq -r .reason)
  exit 250
fi

tsid=$(echo "${HTTP_BODY}" | jq -r .data.testset_id)
printf 'Your test request is accepted - Test Run id : \033[1;32m %d \033[1;0m \n' ${tsid}


start_time=$(date +%s)
testCompleteCheckUrl="https://api.apptest.ai/openapi/v2/testset/${tsid}"

TEST_RUN_RESULT="Running"
while [ "${TEST_RUN_RESULT}" != "Complete" ] && ${waiting_for_test_results}; do
  HTTP_RESPONSE=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" --user ${access_key} ${testCompleteCheckUrl})
  HTTP_BODY=$(echo "${HTTP_RESPONSE}" | sed -e 's/HTTPSTATUS\:.*//g')
  HTTP_STATUS=$(echo "${HTTP_RESPONSE}" | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
  if [ ! ${HTTP_STATUS} -eq 200  ]; then
    echo "Test status query error [HTTP status: ${HTTP_STATUS}]"
    exit 249
  fi

  TEST_RUN_RESULT=$(echo "${HTTP_BODY}" | jq -r .data.testset_status)
  if [ "${TEST_RUN_RESULT}" == "Complete" ]; then
    break
  fi

  sleep 30s
  current_time=$(date +%s)
  wait_time=$((current_time - start_time))
  echo "Waiting for Test Run(ID: ${tsid}) completed for ${wait_time}s"
done

getTestResultUrl="https://api.apptest.ai/openapi/v2/testset/${tsid}/result"
HTTP_RESPONSE=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" --user ${access_key} ${getTestResultUrl})
HTTP_BODY=$(echo "${HTTP_RESPONSE}" | sed -e 's/HTTPSTATUS\:.*//g')
HTTP_STATUS=$(echo "${HTTP_RESPONSE}" | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')

if [ ! ${HTTP_STATUS} -eq 200  ]; then
  echo "Error [HTTP status: ${HTTP_STATUS}]"
  exit 248
fi
RESULT_DATA=$(echo "${HTTP_BODY}" | jq -r .data)


if ${waiting_for_test_results}; then
  if [ ! -d "${test_result_path}" ] ; then
    mkdir "${test_result_path}" || echo "creating directory for test results failed"
  fi

  if [ ! -d "${test_result_path}/apptestai" ] ; then
    mkdir "${test_result_path}/apptestai" || echo "creating directory for test results failed"
  fi

  test_result_txt_file_path="${test_result_path}"/apptestai/results.txt
  test_result_xml_file_path="${test_result_path}"/apptestai/results.xml
  test_result_html_file_path="${test_result_path}"/apptest-ai_result.html

  TEST_RESULT=$(echo ${RESULT_DATA} | jq -r .result_json |  jq -r \ '.testsuites.testsuite[0].testcase[]')
  echo "+-----------------------------------------------------------------+" >  ${test_result_txt_file_path}
  echo "|                        Device                        |  Result  |" >> ${test_result_txt_file_path}
  echo "+-----------------------------------------------------------------+" >> ${test_result_txt_file_path}
  echo ${TEST_RESULT} | jq -r \
       'if has("system-out") then "\""+ .name + "\" \"\\033[1;32m Passed \\033[1;0m\"" else "\"" + .name + "\" \"\\033[1;31m Failed \\033[1;0m\"" end ' \
       | xargs printf "| %-52s | %b | \n"  >> ${test_result_txt_file_path}
  echo "+-----------------------------------------------------------------+" >> ${test_result_txt_file_path}

  cat ${test_result_txt_file_path}
  echo $RESULT_DATA | jq -r .result_xml >  "${test_result_xml_file_path}"  && echo "Test result(JUnit XML) saved: ${test_result_xml_file_path} "
  echo $RESULT_DATA | jq -r .result_html > "${test_result_html_file_path}" && echo "Test result(Full HTML) saved: ${test_result_html_file_path} "
fi

echo "apptest.ai test step completed!"
