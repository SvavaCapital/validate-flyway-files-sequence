#!/bin/bash
set -e  # Exit on first error

MIGRATION_DIR="src/main/resources/db/migrations"

if [ ! -d "$MIGRATION_DIR" ]; then
    echo "❌ Migration directory $MIGRATION_DIR does not exist!"
    exit 1
fi

#echo "Fetching the base branch: $GITHUB_BASE_REF"
#git fetch origin $GITHUB_BASE_REF --unshallow || echo "⚠️ Branch '$GITHUB_BASE_REF' not found in remote"

NEW_FILES=$(git diff --name-only --diff-filter=A origin/dev...origin/PEN-25236)

if [ -z "$NEW_FILES" ]; then
    echo "✅ No new Flyway migrations detected. Skipping validation."
    exit 0
fi

NEW_FILES=$(echo "$NEW_FILES" | grep -E "^$MIGRATION_DIR/V[0-9]+__.*\.sql$" || true)

if [ -z "$NEW_FILES" ]; then
    echo "✅ No new Flyway migrations detected. Skipping validation."
    exit 0
fi

echo "Detected migration files: $NEW_FILES"
EXISTING_VERSIONS=$(ls $MIGRATION_DIR/V*__*.sql | sed -E 's/.*\/V([0-9]+)__.*\.sql/\1/' | sort -n)
NEW_VERSIONS=$(echo "$NEW_FILES" | sed -E 's/.*\/V([0-9]+)__.*\.sql/\1/' | sort -n)

# Remove NEW_VERSIONS from EXISTING_VERSIONS
FILTERED_EXISTING_VERSIONS=$(echo "$EXISTING_VERSIONS" | tr ' ' '\n' | grep -vxF -f <(echo "$NEW_VERSIONS" | tr ' ' '\n') | tr '\n' ' ')

LAST_EXISTING_VERSION=$(echo "$FILTERED_EXISTING_VERSIONS" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -n | tail -n 1)

echo "last existing version: $LAST_EXISTING_VERSION"
echo "new versions: $NEW_VERSIONS"

for version in $NEW_VERSIONS; do
    LAST_EXISTING_VERSION=$((LAST_EXISTING_VERSION + 1))
    if [[ "$version" -ne "$LAST_EXISTING_VERSION" ]]; then
        echo "❌ Flyway migration sequence is broken! Expected V$LAST_EXISTING_VERSION but found V$version."
        exit 1
    fi
done

echo "✅ New Flyway migrations are in the correct sequence."
exit 0

