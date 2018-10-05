#!/bin/bash
#
# Script to report on top PR Reviewers in a given date range.
#
# WARNING: The GitHub GraphQL API sometimes throws random errors when running this script.
# It does it less frequently when number of results returned (per request) is kept to a smaller number (~50)
#
# Run this on Windows via Git Bash (sh.exe):
# e.g. 'sh [script].sh 2018-08'

#-----------------#
# Configurations  #
#-----------------#
# Querying GitHub GraphQL REQUIRES valid access token (with "repo" access), see:
# https://help.github.com/articles/creating-a-personal-access-token-for-the-command-line/
GITHUB_TOKEN="[add-your-token]"

# Location of 'jq' (v1.5) on your system.
# https://stedolan.github.io/jq/download/
# On Linux
#JQ_EXEC = "jq"
# On Windows, remove the ".exe" from the filename (e.g. "./jq-win64")
JQ_EXEC="./jq-win64"

# GitHub Organization(s) to search within.
# Multiple organizations can be space-separated (e.g. "DSpace DSpace-Labs")
# When multiple are specified, a separate CSV per Org is generated
GITHUB_ORGS="DSpace"
#GITHUB_ORGS="DSpace DSpace-Labs"

# Suffix of JSON output file (prefix is Org name)
# This file will store the raw JSON output from GitHub. If multiple pages of results
# are found, this will be a JSON representing the combination of all pages.
# (NOTE however that GitHub APIs supposedly have a max limit of returning only 1,000 results per query)
OUTPUT_JSON_SUFFIX="pr-reviewers.json"

# Suffix of CSV output file (prefix is Org name)
# This file will be the final ranked CSV output (parsed from the raw JSON)
OUTPUT_CSV_SUFFIX="pr-reviewers.csv"

#--------------------------------#
# Parse out required MONTH input #
#--------------------------------#
if [ $# -lt 1 ]; then
  echo "ERROR: Required parameter MONTH is missing."
  echo "Usage: $0 MONTH [REPORT_TYPE]"
  echo "E.g. monthly report: $0 2018-08"
  echo "E.g. yearly report: $0 2018-01 year"
  exit 1
fi
REPORT_MONTH=$1
# Default to a montly report, if second param not provided
REPORT_TYPE=${2:-"month"}

# Determine the report range, based on first day of given month
FIRST_DAY="$REPORT_MONTH-01"
# Date to start report from (anything on or after this "start date" will be included)
START_DATE=`date -d "$FIRST_DAY" +"%Y-%m-%dT%H:%M:%SZ"`
# Date to end report before (anything before this "end date" will be included)
# (Uses bash `date` to do the math, e.g. "2018-01-01+1 year" = "2019-01-01")
END_DATE=`date -d "$FIRST_DAY+1 $REPORT_TYPE" +"%Y-%m-%dT%H:%M:%SZ"`

#-------------------------------------------------#
# Loop through each ORG, compiling stats for each #
# and generating an output file for each.         #
#-------------------------------------------------#
for GITHUB_ORG in $GITHUB_ORGS; do

    # Specify output files, based on ORG name & suffix
    OUTPUT_JSON="$GITHUB_ORG-$OUTPUT_JSON_SUFFIX"
    OUTPUT_CSV="$GITHUB_ORG-$OUTPUT_CSV_SUFFIX"

    echo "Generating $GITHUB_ORG report from $START_DATE to $END_DATE..."

    #--------------------------------------------------#
    # Query GitHub API, saving results to $OUTPUT_JSON #
    #--------------------------------------------------#
    # Before we get started, remove the $OUTPUT_JSON (from any previous script runs)
    # This file will be recreated below.
    if [ -f $OUTPUT_JSON ]; then
      rm $OUTPUT_JSON
    fi

    # Initialize cursor (used for GraphQL pagination) to a default value
    # Cursor is updated in while loop below, if multiple pages are found.
    CURSOR_DEFAULT="firstpage"
    CURSOR=$CURSOR_DEFAULT

    # While $CURSOR is not empty, keep looping.
    # This means there are more pages of results.
    echo "... querying GitHub API for first page of results"
    while [ -n "$CURSOR" ]; do

      # If $CURSOR is default value, set to empty string. No cursor needed in first query.
      if [[ "$CURSOR" == "$CURSOR_DEFAULT" ]]; then
        CURSOR=""
      fi

      # Query in GitHub GraphQL format
      # Query for the first 100 Pull Request updated within the given date range AND having >0 comments (all reviews are considered comments).
      # SubQuery selects only PR Reviews (on returned PRs) which were created since the $START_DATE.
      # This queries across all projects in the $GITHUB_ORG
      # 
      # Test this query online at https://developer.github.com/v4/explorer/
      # (When testing this query you may wish to append "sort:updated-asc" to see results in a logical order)
      #
      # NOTE: Make sure to escape any double quotes (\\\") in query
      # NOTE: Descreasing the "first" value of Issues returned to 50 makes this query less prone to response errors, but requires more pages to gather.
      github_query="query {
        search (first: 50, $CURSOR type: ISSUE, query:\"type:pr user:$GITHUB_ORG comments:>0 updated:$START_DATE..$END_DATE\") {
          edges {
            node {
              ... on PullRequest {
                timeline(since:\"$START_DATE\", first:100) {
                  edges {
                    node {
                      ... on PullRequestReview{
                        url
                        author {
                          ... on User{
                            login
                            company
                          }
                        }
                        pullRequest {
                          url
                          state
                          number
                        }
                      }
                    }
                  }
                }
              }
            }
          }
          pageInfo {
            hasNextPage
            endCursor
          }
        }
      }"

      # Escape double quotes in query
      github_query="$(echo $github_query | sed 's/\"/\\\"/g')"
      # For testing: see query with escaped double quotes
      #echo $github_query

      # Send query to GitHub GraphQL endpoint in JSON format
      # Save the output to temporary file "single_page_output.json"
      PAGE_OUTPUT="single_page_output.json"
      curl --silent -K -i -H 'Content-Type: application/json' \
         -H "Authorization: bearer $GITHUB_TOKEN" \
         -X POST -d "{ \"query\": \"$github_query\"}" https://api.github.com/graphql \
         -o "$PAGE_OUTPUT" 

      # Check if "hasNextPage" is true. If so, return the "endCursor" (which points to next page). If not, return nothing.
      more_results=`$JQ_EXEC 'if .data.search.pageInfo.hasNextPage then .data.search.pageInfo.endCursor else empty end' $PAGE_OUTPUT`
      
      # For testing: See what is in $more_results
      #echo $more_results
  
      # Check for errors returned
      check_errors=`$JQ_EXEC 'if .errors then .errors[].message else empty end' $PAGE_OUTPUT`
      if [ -n "$check_errors" ]; then
        echo "ERROR FROM GITHUB API: ${check_errors}"
        exit 1
      fi

      # If final output file doesn't exist
      if [ ! -f $OUTPUT_JSON ]; then
         echo "... Creating JSON output file ${OUTPUT_JSON}."
         # Copy API output to final output
         $JQ_EXEC '.' $PAGE_OUTPUT > $OUTPUT_JSON
      else
         echo "... Appending new set of results to ${OUTPUT_JSON}."
         # This merges/adds the "data.search.edges[]" array of $PAGE_OUTPUT into that of $OUTPUT_JSON, therefore combining results lists
         # See https://stackoverflow.com/a/42013459/3750035
         # The output is temporarily written to a "temp" file, and then moved over into $OUTPUT_JSON (so that that file has the combined results).
         $JQ_EXEC -n 'reduce inputs as $i (.; .data.search.edges += $i.data.search.edges)' $OUTPUT_JSON $PAGE_OUTPUT > temp && mv temp $OUTPUT_JSON
      fi

      # If more_results is NOT empty, then we have another page
      if [ -n "$more_results" ]; then
        echo "... pagination cursor found: $more_results ... querying for next page"
        # The "endCursor" value (from previous request) should be in $more_results.
        # Create an "after:" query param for the next request to get the next set of results.
        CURSOR="after: ${more_results}, "
      else
        # No more results exist (i.e. this is the last page)
        CURSOR=""
      fi
  
      # Remove our page output file. All results have been merged into $OUTPUT_JSON
      rm $PAGE_OUTPUT
    done # End while loop

    #--------------------------------------------------#
    # Parse $OUTPUT_JSON, using `jq`, into $OUTPUT_CSV #
    #--------------------------------------------------#
    # Create the JQ query
    # JQ: https://stedolan.github.io/jq/
    # Test this query online at: https://jqplay.org/
    # Good guide for complex queries: https://shapeshed.com/jq-json/
    #
    # Human explanation:
    #    1. Return all "data.search.edges[].node.timeline.edges[]" from JSON *AS AN ARRAY*
    #    2. Map that array to another array, filtering out only the reviews that reference a "pullRequest"
    #       (This filters out any empty nodes -- as the original JSON includes empty nodes for *comments* on PRs, as each review is also a comment)
    #    3. Group them by Review author (.node.author.login)
    #    4. Map them to a simple array of "user" (login & company), "reviewed" (URLs of PRs reviewed), filtering out any duplicate PRs
    #       (We filter duplicate PRs, as you can review a PR multiple times -- but we are counting only one review per PR)
    #    5. Map that into a simple array of "user", "reviewed" and "count" (where count is number of reviewed PRs)
    #    6. Sort that array by count (ascending)
    #    7. Finally, reverse the order (to get descending sort -- highest number of reviews listed first)
    jq_query='[ .data.search.edges[].node.timeline.edges[] ] | map(select (.node | has("pullRequest"))) | group_by(.node.author.login) | map( {user: [ .[0].node.author.login, .[0].node.author.company | rtrimstr(" ") ], reviewed: [.[].node.pullRequest.url] | unique | reverse }) | map( {user: .user, reviewed: .reviewed, count: .reviewed | length }) | sort_by(.count) | reverse'

    # Uncomment next two lines to convert to CSV OUTPUT (with headers)
    # This does the following
    #     1. Takes JSON output above and maps to a new structure where all URLs are in one field (separated by semicolons)
    #     2. Output that structure to a flat array, with headers as the first row
    #     3. Call @csv to output flat array to CSV
    jq_query_csv_out='| map( {user: .user | join(";"), count: .count, reviewed: .reviewed | join(";")}) | ["User", "Count", "URLs"], (.[] | [.user, .count, .reviewed]) | @csv'
    jq_query="$jq_query $jq_query_csv_out"

    # Run the JQ query, sending results to STDOUT
    #less $OUTPUT_JSON | $JQ_EXEC "$jq_query"

    # Run the JQ query, sending results to $OUTPUT_CSV
    echo "Parsing ${OUTPUT_JSON} into final results ${OUTPUT_CSV}."
    # 'less' is used to pipe $OUTPUT_JSON as it seems to work better than passing file as param
    less $OUTPUT_JSON | $JQ_EXEC -r "$jq_query" > $OUTPUT_CSV
done # End loop over ORGs
