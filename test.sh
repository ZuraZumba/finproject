#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

if [[ "${BASH_TRACE:-0}" == "1" ]]; then
    set -o xtrace
fi

cd "$(dirname "$0")"

# # ამოწმებს გადაცემულია თუ არა ოთხივე პარამეტრი
# if [ $# -ne 5 ]; then
#   echo "Error: Invalid number of arguments."
#   echo "Usage: $0 CODE_REPO_URL DEV_BRANCH_NAME RELEASE_BRANCH_NAME HTML_REPO_URL HTML_BRANCH_NAME"
#   exit 1
# fi


#am rigitobas aqvs mnishvneloba da davimaxsovrot
CODE_REPO_URL=$1
DEV_BRANCH_NAME=$2
RELEASE_BRANCH_NAME=$3
HTML_REPO_URL=$4
HTML_BRANCH_NAME=$5


REPOSITORY_OWNER=$(echo "$CODE_REPO_URL" | cut -d':' -f2 | cut -d'/' -f1)
REPOSITORY_NAME_CODE=$(echo "$CODE_REPO_URL" | cut -d'/' -f2 | cut -d'.' -f1)
REPORT_OWNER=$(echo "$HTML_REPO_URL" | cut -d':' -f2 | cut -d'/' -f1)
REPOSITORY_NAME_REPORT=$(echo "$HTML_REPO_URL" | cut -d'/' -f2 | cut -d'.' -f1)
REPOSITORY_BRANCH_CODE=$DEV_BRANCH_NAME
REPOSITORY_BRANCH_RELEASE=$RELEASE_BRANCH_NAME
REPOSITORY_BRANCH_REPORT=$HTML_BRANCH_NAME
REPOSITORY_PATH_CODE=$(mktemp --directory)
REPOSITORY_PATH_REPORT=$(mktemp --directory)
PYTEST_REPORT_PATH=$(mktemp)
BLACK_OUTPUT_PATH=$(mktemp)
BLACK_REPORT_PATH=$(mktemp)
PYTEST_RESULT=0
BLACK_RESULT=0

function github_api_get_request()
{
    curl --request GET \
        --header "Accept: application/vnd.github+json" \
        --header "Authorization: Bearer $GITHUB_PERSONAL_ACCESS_TOKEN" \
        --header "X-GitHub-Api-Version: 2022-11-28" \
        --output "$2" \
        --silent \
        "$1"
        #--dump-header /dev/stderr \
}

function github_post_request()
{
    curl --request POST \
        --header "Accept: application/vnd.github+json" \
        --header "Authorization: Bearer $GITHUB_PERSONAL_ACCESS_TOKEN" \
        --header "X-GitHub-Api-Version: 2022-11-28" \
        --header "Content-Type: application/json" \
        --silent \
        --output "$3" \
        --data-binary "@$2" \
        "$1"
        #--dump-header /dev/stderr \
}

function jq_update()
{
    local IO_PATH=$1
    local TEMP_PATH=$(mktemp)
    shift
    cat $IO_PATH | jq "$@" > $TEMP_PATH
    mv $TEMP_PATH $IO_PATH
}

run_test() {
 
    COMMIT_HASH=$(git rev-parse HEAD)
    AUTHOR_EMAIL=$(git log -n 1 --format="%ae" HEAD)


    if pytest --verbose --html=$PYTEST_REPORT_PATH --self-contained-html
    then
        PYTEST_RESULT=$?
        echo "PYTEST SUCCEEDED $PYTEST_RESULT"
    else
        PYTEST_RESULT=$?
        echo "PYTEST FAILED $PYTEST_RESULT"
    fi

    echo "\$PYTEST_RESULT = $PYTEST_RESULT \$BLACK_RESULT=$BLACK_RESULT"

    if black --check --diff *.py > $BLACK_OUTPUT_PATH
    then
        BLACK_RESULT=$?
        echo "BLACK SUCCEEDED $BLACK_RESULT"
    else
        BLACK_RESULT=$?
        echo "BLACK FAILED $BLACK_RESULT"
        cat $BLACK_OUTPUT_PATH | pygmentize -l diff -f html -O full,style=solarized-light -o $BLACK_REPORT_PATH
    fi

    echo "\$PYTEST_RESULT = $PYTEST_RESULT \$BLACK_RESULT=$BLACK_RESULT"


    
}

run_report(){
    git clone git@github.com:${REPORT_OWNER}/${REPOSITORY_NAME_REPORT}.git $REPOSITORY_PATH_REPORT

    pushd $REPOSITORY_PATH_REPORT

    git switch $REPOSITORY_BRANCH_REPORT
    REPORT_PATH="${COMMIT_HASH}-$(date +%s)"
    mkdir --parents $REPORT_PATH
    mv $PYTEST_REPORT_PATH "$REPORT_PATH/pytest.html"
    mv $BLACK_REPORT_PATH "$REPORT_PATH/black.html"
    git add $REPORT_PATH
    git commit -m "$COMMIT_HASH report."
    git push

    popd

    rm -rf $REPOSITORY_PATH_CODE
    rm -rf $REPOSITORY_PATH_REPORT
    rm -rf $PYTEST_REPORT_PATH
    rm -rf $BLACK_REPORT_PATH

    if (( ($PYTEST_RESULT != 0) || ($BLACK_RESULT != 0) ))
    then
        AUTHOR_USERNAME=""
        # https://docs.github.com/en/rest/search?apiVersion=2022-11-28#search-users
        RESPONSE_PATH=$(mktemp)
        github_api_get_request "https://api.github.com/search/users?q=$AUTHOR_EMAIL" $RESPONSE_PATH

        TOTAL_USER_COUNT=$(cat $RESPONSE_PATH | jq ".total_count")

        if [[ $TOTAL_USER_COUNT == 1 ]]
        then
            USER_JSON=$(cat $RESPONSE_PATH | jq ".items[0]")
            AUTHOR_USERNAME=$(cat $RESPONSE_PATH | jq --raw-output ".items[0].login")
        fi

        REQUEST_PATH=$(mktemp)
        RESPONSE_PATH=$(mktemp)
        echo "{}" > $REQUEST_PATH

        BODY+="Automatically generated message

"

        if (( $PYTEST_RESULT != 0 ))
        then
            if (( $BLACK_RESULT != 0 ))
            then
                TITLE="${COMMIT_HASH::7} failed unit and formatting tests."
                BODY+="${COMMIT_HASH} failed unit and formatting tests.

"
                jq_update $REQUEST_PATH '.labels = ["ci-pytest", "ci-black"]'
            else
                TITLE="${COMMIT_HASH::7} failed unit tests."
                BODY+="${COMMIT_HASH} failed unit tests.

"
                jq_update $REQUEST_PATH '.labels = ["ci-pytest"]'
            fi
        else
            TITLE="${COMMIT_HASH::7} failed formatting test."
            BODY+="${COMMIT_HASH} failed formatting test.
"
            jq_update $REQUEST_PATH '.labels = ["ci-black"]'
        fi

        BODY+="Pytest report: https://${REPORT_OWNER}.github.io/${REPOSITORY_NAME_REPORT}/$REPORT_PATH/pytest.html

"
        BODY+="Black report: https://${REPORT_OWNER}.github.io/${REPOSITORY_NAME_REPORT}/$REPORT_PATH/black.html

"

        jq_update $REQUEST_PATH --arg title "$TITLE" '.title = $title'
        jq_update $REQUEST_PATH --arg body  "$BODY"  '.body = $body'

        if [[ ! -z $AUTHOR_USERNAME ]]
        then
            jq_update $REQUEST_PATH --arg username "$AUTHOR_USERNAME"  '.assignees = [$username]'
        fi

        # https://docs.github.com/en/rest/issues/issues?apiVersion=2022-11-28#create-an-issue
        github_post_request "https://api.github.com/repos/${REPORT_OWNER}/${REPOSITORY_NAME_CODE}/issues" $REQUEST_PATH $RESPONSE_PATH
        #cat $RESPONSE_PATH
        # HTML_URL=$(echo "$USER_JSON" | jq -r '.html_url')
        cat $RESPONSE_PATH | jq -r '.html_url'
        # html_url=$(cat $RESPONSE_PATH | jq -r ".html_url")

        rm $RESPONSE_PATH
        rm $REQUEST_PATH
        else
            echo "EVERYTHING OK, BYE!"
           
        fi

}

# Replace 'your-username' and 'your-repo' with the respective GitHub username and repository name
GITHUB_REPO="$REPOSITORY_OWNER/$REPOSITORY_NAME_CODE"

# Function to check for new commits
check_commits() {
    URL="https://api.github.com/repos/$GITHUB_REPO/commits"
    HEADERS="Authorization: token $GITHUB_PERSONAL_ACCESS_TOKEN"
    LATEST_COMMIT=$(curl -s -H "$HEADERS" "$URL" | jq -r '.[0].sha')

    if [ "$LATEST_COMMIT" != "$LAST_COMMIT_SHA" ]; then
        echo "New commits found! Pulling changes..."

        # Perform any additional actions you want here, like pulling changes locally.
        # Example: git -C /path/to/your/git/repository pull origin master
        LAST_COMMIT_SHA=$LATEST_COMMIT
        echo $LAST_COMMIT_SHA
    git clone git@github.com:${REPOSITORY_OWNER}/${REPOSITORY_NAME_CODE}.git $REPOSITORY_PATH_CODE
    pushd $REPOSITORY_PATH_CODE
    git switch $REPOSITORY_BRANCH_CODE
    run_test
    popd
    #ცვლადები გასასწორებელია
    run_report
    else
        echo "No new commits found. Sleeping for 15 seconds..."
    fi
}

# Initialize the variable to store the last commit SHA
LAST_COMMIT_SHA=""

while true; do
    check_commits
    sleep 15
done

