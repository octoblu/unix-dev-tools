#!/bin/bash

assert_hub(){
  hub --version &> /dev/null \
  || die 'hub not found, `brew install hub`'

  echo "" | hub issue &> /dev/null \
  || die 'hub not logged in, run `hub issue` and fill in the prompts'
}

bump_version(){
  local version="$1"
  local bump="$2"
  if [ -f .version ]; then
    rm .version
  fi
  semver init "$version" > /dev/null
  local new_version="$(semver bump "$2")"
  rm .version
  echo "$new_version"
}

check_for_git_pairing() {
  if [ "$(gem list git-pairing --installed)" == 'true' ]; then
    return 0
  fi
  return 1
}

check_master(){
  CURRENT_BRANCH=`git rev-parse --abbrev-ref HEAD`
  if [ "$CURRENT_BRANCH" != "master" ]; then
    echo ''
    echo 'ERROR: this project is not in the master branch!'
    echo `git status | head -1`
    echo ''
    exit 1
  fi
}

check_git(){
  git fetch origin
  local get_log="$(git log HEAD..origin/master --oneline)"
  if [[ -n "$get_log" ]]; then
    echo ''
    echo 'WARNING: this project is behind remote!'
    echo "$get_log"
    echo ''
    local git_pull=''
    read -s -p "press 'y' to pull, any other key to exit"$'\n' -n 1 git_pull
    if [[ "$git_pull" == 'y' ]]; then
      echo 'pulling...'
      git pull
    else
      exit 1
    fi
  fi
}

die(){
  local message="$1"
  echo "$message"
  exit 1
}

do_git_stuff(){
  local new_version="$1"
  local message="$2"
  local full_version="v${new_version}"
  local full_message="${full_version}"
  if [ ! -z "$message" ]; then
    full_message="${full_message} ${message}"
  fi

  echo "Warning! About to run the following commands:"
  echo "  1. git add ."
  echo "  2. git commit --message \"$full_message\""
  echo "  3. git tag $full_version"
  echo "  4. git push"
  echo "  5. git push --tags"
  echo '  6. Run: git push'
  echo '  7. Run: git push --tags'
  echo "  8. Run: hub release create -m \"$full_message\" \"$full_version\""
  echo ""
  echo "AND we will be changing your package.json, version.go, and VERSION"
  echo ""
  read -s -p "press 'y' to run the above commands, any other key to exit"$'\n' -n 1 DO_GIT
  if [[ "$DO_GIT" == "y" ]]; then
    modify_file "$new_version"
    echo "Releasing ${full_version}..." \
    &&  git add . \
    &&  git commit --message "$full_message" \
    &&  git tag "$full_version" \
    &&  git push \
    &&  git push --tags \
    &&  sleep 10 \
    &&  hub release create -m "$full_message" "$full_version"
  fi
}

get_project_version(){
  if [ -f "./package.json" ]; then
    jq '.version' --raw-output ./package.json
    return
  fi

  if [ -f "./version.go" ]; then
    grep --only-matching '[0-9]*\.[0-9]*\.[0-9]' ./version.go
    return
  fi

  if [ -f "./VERSION" ]; then
    grep --only-matching '[0-9]*\.[0-9]*\.[0-9]' ./VERSION
    return
  fi

  local latest_tag="$(git tag --list | grep '^v[0-9]\+\.[0-9]\+\.[0-9]\+' | gsort -V | tail -n 1)"
  local version="${latest_tag/v/}"
  echo "$version"
}

get_bump(){
  local cmd="$1"
  local bump=''
  if [ "$cmd" == '--major' ]; then
    bump='major'
  fi

  if [ "$cmd" == '--minor' ]; then
    bump='minor'
  fi

  if [ "$cmd" == '-p' ]; then
    bump='patch'
  fi

  if [ "$cmd" == '--patch' ]; then
    bump='patch'
  fi

  if [ "$cmd" == '-i' ]; then
    bump='init'
  fi

  if [ "$cmd" == '--init' ]; then
    bump='init'
  fi

  echo "$bump"
}

modify_file(){
  local version="$1"
  if [ -f "./package.json" ]; then
    echo 'Modifying package.json'
    local packageJSON="$(cat ./package.json)"
    echo "$packageJSON" | jq --raw-output ".version=\"$version\"" > ./package.json
  fi

  if [ -f "./version.go" ]; then
    echo 'Modifying version.go'
    local versionGo="$(cat ./version.go)"
    echo "$versionGo" | sed -e "s/[0-9]*\.[0-9]*\.[0-9]*/$version/" > ./version.go
  fi

  if [ -f "./VERSION" ]; then
    echo 'Modifying VERSION'
    local versionBash="$(cat VERSION)"
    echo "$versionBash" | sed -e "s/[0-9]*\.[0-9]*\.[0-9]*/$version/" > ./VERSION
  fi
}

prompt_for_user() {
  local users=""
  read -p 'Add author(s): ' users
  local users_count="$(echo "$users" | wc -w | xargs)"
  if [ "$users_count" == '1' ]; then
    git solo $users
  else
    git pair $users
  fi
}

usage(){
  echo 'USAGE: gump [<message>] [(--major|--minor|--patch)]'
  echo ''
  echo 'example: gump "added some awesome feature" --minor'
  echo ''
  echo '  --major         major version bump. 1.0.0 -> 2.0.0'
  echo '  --minor         minor version bump. 1.0.0 -> 1.1.0'
  echo '  -p, --patch     patch version bump. 1.0.0 -> 1.0.1 (default)'
  echo '  -i, --init      set the version to 1.0.0'
  echo '  -h, --help      print this help text'
  echo '  -v, --version   print the version'
  echo ''
  echo 'But what does it do? It will:'
  echo '  1. Check if your project is out of sync'
  echo '  2. Modify the package.json, version.go, VERSION, or do nothing'
  echo '  3. Run: git add .'
  echo '  4. Run: git commit -m "<new-version> <message>"'
  echo '  5. Run: git tag <new-version>'
  echo '  6. Run: git push'
  echo '  7. Run: git push --tags'
  echo '  8. Run: hub release create -m "<message>" <new-version>'
}

script_directory(){
  local source="${BASH_SOURCE[0]}"
  local dir=""

  while [ -h "$source" ]; do # resolve $source until the file is no longer a symlink
    dir="$( cd -P "$( dirname "$source" )" && pwd )"
    source="$(readlink "$source")"
    [[ $source != /* ]] && source="$dir/$source" # if $source was a relative symlink, we need to resolve it relative to the path where the symlink file was located
  done

  dir="$( cd -P "$( dirname "$source" )" && pwd )"

  echo "$dir"
}

version(){
  local directory="$(script_directory)"
  local version=$(cat "$directory/VERSION")

  echo "$version"
  exit 0
}

main(){
  local cmd="$1"
  local cmd2="$2"

  if [ "$cmd" == '--help' -o "$cmd" == '-h' ]; then
    usage
    exit 0
  fi

  if [ "$cmd" == '--version' -o "$cmd" == '-v' ]; then
    version
    exit 0
  fi

  local bump="$(get_bump "$cmd")"
  local message=""
  if [ -z "$bump" ]; then
    bump="$(get_bump "$cmd2")"
    message="$cmd"
  else
    message="$cmd2"
  fi

  if [ -z "$bump" ]; then
    bump='patch'
  fi

  check_master
  local master_okay="$?"
  if [ "$master_okay" != "0" ]; then
    echo 'Not on master branch, exiting'
    exit 1
  fi

  check_git
  local git_okay="$?"
  if [ "$git_okay" != "0" ]; then
    echo 'Git syncing error, exiting'
    exit 1
  fi

  check_for_git_pairing
  local git_pairing_install="$?"

  if [ "$git_pairing_install" != "0" ]; then
    echo 'Missing git-pairing dependency'
    echo 'Run: gem install git-pairing'
    exit 1
  fi

  assert_hub

  prompt_for_user
  local user_prompt_okay="$?"

  if [ "$user_prompt_okay" != "0" ]; then
    echo 'Adding authors, exiting'
    exit 1
  fi

  local version="$(get_project_version)"
  local new_version='1.0.0'

  if [ "$bump" != 'init' ]; then
    new_version="$(bump_version "$version" "$bump")"
  fi

  echo "Changing version $version -> $new_version"
  do_git_stuff "$new_version" "$message"
}

main "$@"
