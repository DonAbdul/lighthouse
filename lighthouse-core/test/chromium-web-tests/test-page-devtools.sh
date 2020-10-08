#!/usr/bin/env bash

##
# @license Copyright 2020 The Lighthouse Authors. All Rights Reserved.
# Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and limitations under the License.
##

if [ -z "$1" ]; then
    echo "ERROR: No URL provided."
    exit 1
fi

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
LH_ROOT="$SCRIPT_DIR/../../.."
TEST_DIR="$LH_ROOT/.tmp/chromium-web-tests"

# Setup dependencies.
export DEPOT_TOOLS_PATH="$TEST_DIR/depot-tools"
export DEVTOOLS_PATH=${DEVTOOLS_PATH:-"$TEST_DIR/devtools/devtools-frontend"}
export BLINK_TOOLS_PATH="$TEST_DIR/blink_tools"
export PATH=$DEPOT_TOOLS_PATH:$PATH

bash "$SCRIPT_DIR/download-depot-tools.sh"
bash "$SCRIPT_DIR/download-devtools.sh"
bash "$SCRIPT_DIR/download-blink-tools.sh"
bash "$SCRIPT_DIR/download-content-shell.sh"

set -euo pipefail

# Get newest folder
latest_content_shell_dir=$(ls -t "$LH_ROOT/.tmp/chromium-web-tests/content-shells/" | head -n1)
latest_content_shell="$LH_ROOT/.tmp/chromium-web-tests/content-shells/$latest_content_shell_dir"

roll_devtools() {
  # Roll devtools. Besides giving DevTools the latest lighthouse source files,
  # this also copies over the webtests.
  cd "$LH_ROOT"
  yarn devtools "$DEVTOOLS_PATH"
  cd -
}

# Run a very basic server on port 8000. Only thing we need is:
#   - /devtools -> the layout tests for devtools frontend
#   - /inspector-sources -> the inspector resources from the content shell
#   - CORS (Access-Control-Allow-Origin header)

# Setup inspector-sources.
cd "$DEVTOOLS_PATH"
git --no-pager log -1
roll_devtools
autoninja -C out/Default # Build devtools resources.
cd -
ln -s "$DEVTOOLS_PATH/out/Default/resources/inspector" "$DEVTOOLS_PATH/test/webtests/http/tests/inspector-sources"

# Add test to run lighthouse in DevTools and print LHR.
echo "
(async function() {
  await TestRunner.navigatePromise('$1');

  await TestRunner.loadModule('lighthouse_test_runner');
  await TestRunner.showPanel('lighthouse');

  LighthouseTestRunner.getRunButton().click();
  const {lhr} = await LighthouseTestRunner.waitForResults();
  TestRunner.addResult(JSON.stringify(lhr));

  TestRunner.completeTest();
})();
" > "$DEVTOOLS_PATH/test/webtests/http/tests/devtools/lighthouse/lighthouse-run-dt.js"

# Kill background jobs and remove temporary files when script ends.
cleanup() {
  rm "$DEVTOOLS_PATH/test/webtests/http/tests/inspector-sources"
  rm "$DEVTOOLS_PATH/test/webtests/http/tests/devtools/lighthouse/lighthouse-run-dt.js"
  kill ${SERVER_PID}
}
trap 'cleanup' EXIT

# Serve from devtools frontend webtests folder.
(npx http-server@0.12.3 "$DEVTOOLS_PATH/test/webtests/http/tests" -p 8000 --cors > /dev/null 2>&1) &
SERVER_PID=$!

echo "Waiting for server"
health_check_url='http://localhost:8000/inspector-sources/integration_test_runner.html?experiments=true&test=http://127.0.0.1:8000/devtools/lighthouse/lighthouse-view-trace-run.js'
until $(curl --output /dev/null --silent --head --fail $health_check_url); do
  printf '.'
  sleep 1
done
echo "Server is up"

# webtests sometimes error if results are already present.
rm -rf "$latest_content_shell/out/Release/layout-test-results"

# Add typ to python path. The regular method assumes there is a Chromium checkout.
export PYTHONPATH="${PYTHONPATH:-}:$BLINK_TOOLS_PATH/latest/third_party/typ"

# Don't quit if the python command fails.
set +e
# Print the python command.
set -x

python \
  "$BLINK_TOOLS_PATH/latest/third_party/blink/tools/run_web_tests.py" \
  --layout-tests-directory="$DEVTOOLS_PATH/test/webtests" \
  --build-directory="$latest_content_shell/out" \
  --no-show-results \
  --time-out-ms=60000 \
  http/tests/devtools/lighthouse/lighthouse-run-dt.js

set +x
set -e

rm -rf "$LH_ROOT/.tmp/layout-test-results"

# Copy results to latest-run folder.
# Sometimes there will be extra output before the line with LHR. To get around this, only copy the last line with content.
awk '/./{line=$0} END{print line}' \
"$latest_content_shell/out/Release/layout-test-results/http/tests/devtools/lighthouse/lighthouse-run-dt-actual.txt" \
> "$LH_ROOT/latest-run/devtools-lhr.json" 
