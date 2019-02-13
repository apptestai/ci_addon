#!/usr/bin/env bash
set -e
	   access_key=${APPTEST_AI_ACCESS_KEY}

           if [ -z "${binary_path}" ]; then
             echo "Test app's binary path is needed"
             exit 255
           fi

           if [ -z "${project_id}" ]; then
             echo "Apptest.ai project id is needed"
             exit 254
           fi

           if [ -z "${access_key}" ]; then
             echo "apptest ai access key should be set as APPTEST_AI_ACCESS_KEY"
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
	   if [ ${TRAVIS_OS_NAME} = "linux" ]; then
              sudo apt-get install jq > /dev/null 2>&1 || { echo "JQ install failed Please email to contact@apptest.ai"; exit 256;}
	   elif [ ${TRAVIS_OS_NAME} = "osx" ]; then
	      brew install jq > /dev/null 2>&1 || { echo "jq install failed please email to contact@apptest.ai"; exit 256; }
	   else
	      echo "unknown os name : ${TRAVIS_OS_NAME} "
	      exit 256
	   fi

           serviceHost=https://api.apptest.ai
           apk_file_d='apk_file=@'\"${binary_path}\"
           data_d='data={"pid":'${project_id}',"test_set_name":"circleci"}'
           testRunUrl=${serviceHost}/openapi/v1/test/run
           HTTP_RESPONSE=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" -F ${apk_file_d} -F ${data_d} -u ${access_key} ${testRunUrl})

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

           tsid=$(echo "${HTTP_BODY}" | jq -r .data.tsid)
           echo 'Your test request is accepted - Test Run id : '${tsid}

           start_time=$(date +%s)
           testCompleteCheckUrl=${serviceHost}/openapi/v1/project/${project_id}/testset/${tsid}/result/all

           TEST_RUN_RESULT=false
           while ! ${TEST_RUN_RESULT} && ${waiting_for_test_results}; do
             HTTP_RESPONSE=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" -u ${access_key} ${testCompleteCheckUrl})
             HTTP_BODY=$(echo "${HTTP_RESPONSE}" | sed -e 's/HTTPSTATUS\:.*//g')
             HTTP_STATUS=$(echo "${HTTP_RESPONSE}" | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
             if [ ! ${HTTP_STATUS} -eq 200  ]; then
               echo "Test status query error [HTTP status: ${HTTP_STATUS}]"
               exit 249
             fi

             TEST_RUN_RESULT=$(echo "${HTTP_BODY}" | jq -r .complete)
             if ${TEST_RUN_RESULT}; then
               RESULT_DATA=$(echo "${HTTP_BODY}" | jq -r .data)
               break
             fi

             current_time=$(date +%s)
             wait_time=$((current_time - start_time))
             echo "Waiting for Test Run(ID: ${tsid}) completed for ${wait_time}s"
             sleep 30s
          done
          if ${waiting_for_test_results}; then
             TEST_RESULT=$(echo ${RESULT_DATA} | jq -r .result_json |  jq -r \ '.testsuites.testsuite[0].testcase[]')
             echo "+-----------------------------------------------------------------+"
             echo "|                        Device                        |  Result  |"
             echo "+-----------------------------------------------------------------+"
             echo ${TEST_RESULT} | jq -r \
                  'if has("system-out") then "\""+ .name + "\" \" Passed \"" else "\"" + .name + "\" \" Failed \" " end ' \
                  | xargs printf "| %-52s | %b | \n"
             echo "+-----------------------------------------------------------------+"

             if [ ! -d "${test_result_path}" ] ; then
               mkdir "${test_result_path}" || echo "creating directory for test results failed"
             fi
             mkdir "${test_result_path}"/apptestai
             test_result_xml_file_path="${test_result_path}"/apptestai/results.xml
             test_result_html_file_path="${test_result_path}"/apptest-ai_result.html
             echo $RESULT_DATA | jq -r .result_xml >  "${test_result_xml_file_path}"  && echo "Test result(JUnit XML) saved: ${test_result_xml_file_path} "
             echo $RESULT_DATA | jq -r .result_html > "${test_result_html_file_path}" && echo "Test result(Full HTML) saved: ${test_result_html_file_path} "
           fi
           echo "apptest.ai test step completed!"
