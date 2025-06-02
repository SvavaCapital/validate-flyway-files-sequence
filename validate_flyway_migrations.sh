#!/bin/bash
###############################################################################
# validate-migrations.sh
#
# This script validates the integrity and continuity of Flyway-style SQL
# migration and fixture versioning in a project, typically used in CI/CD.
#
# It performs the following key operations:
# 1. Validates that the migration directory exists.
# 2. Collects all existing migration versions from `db/migration`.
# 3. Compares the current branch with the base branch (GitHub context) to find
#    newly added migration and fixture files.
# 4. Verifies that new migration versions:
#    - Are strictly increasing and continuous with no gaps.
#    - Start exactly from the next version after the latest existing one.
# 5. Validates that fixture files (from `db/fixtures`):
#    - Have valid major versions matching either existing or new migration versions.
#    - Contain continuous minor versioning starting from 1 for each major.
#
# Usage:
# Typically used in CI environments like GitHub Actions. Relies on the
# environment variables:
#   - GITHUB_BASE_REF
#   - GITHUB_HEAD_REF
#
# Exit codes:
#   0  - All validations passed.
#   1  - Any structural or versioning issue detected.
###############################################################################

set -e

# Use environment variables (set in GitHub Action) or fall back to defaults
MIGRATION_DIR=${MIGRATION_DIR:-"src/main/resources/db/migrations"}
FIXTURES_DIR=${FIXTURES_DIR:-"src/main/resources/db/fixtures"}

echo "🔵 Using migration directory: $MIGRATION_DIR"
echo "🔵 Using fixtures directory: $FIXTURES_DIR"

if [ ! -d "$MIGRATION_DIR" ]; then
    echo "❌ Migration directory $MIGRATION_DIR does not exist!"
    exit 1
fi

# Safely collect all migration files across folders
migration_files=($(find "$MIGRATION_DIR" -type f -name 'V*__*.sql'))

ALL_MIGRATION_VERSIONS=$(for file in "${migration_files[@]}"; do
  if [[ "$file" =~ /V([0-9]+)__.*\.sql$ ]]; then
    echo "${BASH_REMATCH[1]}"
  fi
done | sort -n | uniq)

## Fetch base branch if not present
#if ! git rev-parse --verify "$GITHUB_BASE_REF" >/dev/null 2>&1; then
#  echo "🔄 Fetching base branch '$GITHUB_BASE_REF'..."
#  git fetch origin "$GITHUB_BASE_REF:$GITHUB_BASE_REF"
#fi
#
#if ! git rev-parse --verify "$GITHUB_HEAD_REF" >/dev/null 2>&1; then
#  echo "🔄 Fetching current branch '$GITHUB_HEAD_REF'..."
#  git fetch origin "$GITHUB_HEAD_REF:$GITHUB_HEAD_REF"
#fi

#CURRENT_BRANCH=$(git rev-parse --abbrev-ref $GITHUB_HEAD_REF)
# Use BASE_BRANCH from GitHub Actions environment
#BASE_BRANCH=$GITHUB_BASE_REF

#echo "🔵 Base branch: $BASE_BRANCH"
#echo "🔵 Current branch: $CURRENT_BRANCH"

#NEW_FILES=$(git diff --name-only --diff-filter=A "$BASE_BRANCH...$CURRENT_BRANCH")
NEW_FILES=$(git diff --name-only --diff-filter=A "origin/$GITHUB_BASE_REF...origin/$GITHUB_HEAD_REF")
NEW_MIGRATIONS=$(echo "$NEW_FILES" | grep -E "^$MIGRATION_DIR/.*/V[0-9]+__.*\.sql$" || true)
NEW_VERSIONS=$(echo "$NEW_MIGRATIONS" | sed -E 's/.*\/V([0-9]+)__.*\.sql/\1/' | sort -n | uniq)

echo "📗 New migration versions: $NEW_VERSIONS"

# Combine existing and new versions
ALL_VERSIONS=$(echo -e "$ALL_MIGRATION_VERSIONS\n$NEW_VERSIONS" | grep -E '^[0-9]+$' | sort -n | uniq)

# Prepare ALL_VERSIONS and NEW_VERSIONS cleanly
ALL_VERSIONS_SORTED=$(echo "$ALL_VERSIONS" | grep -E '^[0-9]+$' | sort -n | uniq)
NEW_VERSIONS_SORTED=$(echo "$NEW_VERSIONS" | grep -E '^[0-9]+$' | sort -n | uniq)

# Now subtract manually
EXISTING_VERSIONS=""
for version in $ALL_VERSIONS_SORTED; do
    if ! echo "$NEW_VERSIONS_SORTED" | grep -qx "$version"; then
        EXISTING_VERSIONS="$EXISTING_VERSIONS"$'\n'"$version"
    fi
done

# Pick the highest one
LATEST_MAJOR=$(echo "$EXISTING_VERSIONS" | grep -E '^[0-9]+$' | sort -n | tail -n 1)

echo "📕 Latest major version (before new migrations): $LATEST_MAJOR"

# Handle case where no new migration versions are found
if [ -z "$NEW_VERSIONS" ]; then
    echo "ℹ️ No new migration files detected."
else
    echo "📗 New migration versions: $NEW_VERSIONS"

    # Validate sequential continuity of new migration versions
    expected=$((LATEST_MAJOR + 1))
    while read -r version; do
        if [[ "$version" -ne "$expected" ]]; then
            echo "❌ Migration version sequence broken! Expected V$expected but found V$version."
            exit 1
        fi
        expected=$((expected + 1))
    done <<< "$NEW_VERSIONS"

    echo "✅ New migration version sequence is valid and strictly increasing with no gaps."
fi

VALID_MAJORS=$(echo -e "$NEW_VERSIONS\n$LATEST_MAJOR" | grep -E '^[0-9]+$' | sort -n | uniq)
echo "📘 Valid fixture major versions: $VALID_MAJORS"

# Gather fixture versions based only on the new migration versions (this happens independently)
# Initialize an empty array to store fixture versions
existing_minor_versions=()

NEW_FIXTURES=$(echo "$NEW_FILES" | grep -E "^$FIXTURES_DIR/.*/V[0-9]+.[0-9]+__.*\.sql$" || true)

# Handle case where no new migration versions are found
if [ -z "$NEW_FIXTURES" ]; then
    echo "ℹ️ No new fixture files detected."
else
    echo "📗 New fixture versions: $NEW_FIXTURES"
fi

# Clean minor version holders
existing_minor_versions=""

existing_fixture_files=($(find "$FIXTURES_DIR" -type f -name 'V[0-9]*.[0-9]*__*.sql'))

# Track max minor version per major using dynamic variables
for file in "${existing_fixture_files[@]}"; do
    if [[ "$file" =~ V([0-9]+)\.([0-9]+)__.*\.sql ]]; then
        major="${BASH_REMATCH[1]}"
        minor="${BASH_REMATCH[2]}"

        # Get current max minor for this major
        eval "current_max_minor=\${existing_max_minor_$major:-0}"

        if (( minor > current_max_minor )); then
            eval "existing_max_minor_$major=$minor"
        fi
    fi
done

# Build current fixture state
for file in $NEW_FIXTURES; do
    if [[ "$file" =~ V([0-9]+)\.([0-9]+)__.*\.sql ]]; then
        major="${BASH_REMATCH[1]}"
        minor="${BASH_REMATCH[2]}"

        # Check if major is allowed
        ALLOWED=false
        for allowed_major in $VALID_MAJORS; do
            if [[ "$major" -eq "$allowed_major" ]]; then
                ALLOWED=true
                break
            fi
        done

        if [[ "$ALLOWED" == false ]]; then
            echo "❌ Fixture file '$file' has invalid major version V$major.$minor. Allowed: $VALID_MAJORS"
            exit 1
        fi

        # Dynamically create a variable per major version
        eval "existing_minor_versions_$major=\"\${existing_minor_versions_$major} $minor\""
    else
        echo "⚠️ File '$file' does not match fixture naming convention."
        exit 1
    fi
done

# Validate minor sequences
for major in $VALID_MAJORS; do
    eval "minors=\"\$existing_minor_versions_$major\""

    if [[ -z "$minors" ]]; then
        continue
    fi

    eval "existing_max=\${existing_max_minor_$major:-0}"
    expected=$((existing_max))
    minors_sorted=$(echo "$minors" | tr ' ' '\n' | grep -v '^$' | sort -n)

    while read -r minor; do
        if [[ "$minor" -ne "$expected" ]]; then
            echo "❌ Minor version sequence error for V$major. Expected minor $expected but found $minor."
            exit 1
        fi
        expected=$((expected + 1))
    done <<< "$minors_sorted"
done

echo "✅ New fixture version sequence is valid and strictly increasing with no gaps."
exit 0
