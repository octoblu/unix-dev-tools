#!/bin/bash

assert_hub(){
  hub --version &> /dev/null \
  || die 'hub not found, `brew install hub`'

  echo "" | hub issue &> /dev/null \
  || die 'hub not logged in, run `hub issue` and fill in the prompts'
}

assert_curl(){
  curl --version &> /dev/null \
  || die 'curl not found, `brew install curl`'
}

assert_required_env() {
  if [ -z "$BEEKEEPER_URI" ]; then
    die '$BEEKEEPER_URI environment not found and is required. Make sure dotfiles are up to date.'
  fi
}

parse_yaml() {
   local prefix=$2
   local s='[[:space:]]*' w='[a-zA-Z0-9_]*' fs=$(echo @|tr @ '\034')
   sed -ne "s|^\($s\)\($w\)$s:$s\"\(.*\)\"$s\$|\1$fs\2$fs\3|p" \
        -e "s|^\($s\)\($w\)$s:$s\(.*\)$s\$|\1$fs\2$fs\3|p"  $1 |
   awk -F$fs '{
      indent = length($1)/2;
      vname[indent] = $2;
      for (i in vname) {if (i > indent) {delete vname[i]}}
      if (length($3) > 0) {
         vn=""; for (i=0; i<indent; i++) {vn=(vn)(vname[i])("_")}
         printf("local %s%s%s=%s\n", "'$prefix'",vn, $2, $3);
      }
   }'
}

parse_gump_config() {
  if [ -f ./.gump.yml ]; then
    parse_yaml ./.gump.yml "gump_config_"
  fi
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

do_deploy(){
  local new_version="$1"
  local beekeeper_uri="$BEEKEEPER_URI"
  local tag="v$new_version"
  local slug="$(git remote show origin -n | grep h.URL | sed 's/.*://;s/.git$//')"
  echo ''
  echo "Creating Deployment: $slug/$tag"
  curl --silent --fail -X POST "$beekeeper_uri/deployments/$slug/$tag"
  local status=$?
  if [ $status -ne 0 ]; then
    echo ''
    echo "Deploy Failed!!!!!!!!"
    echo ''
  fi
}

do_git_stuff(){
  local new_version="$1"
  local message="$2"
  local tag="v$new_version"
  local slug="$(git remote show origin -n | grep h.URL | sed 's/.*://;s/.git$//')"
  local full_version="v${new_version}"
  local full_message="${full_version}"
  if [ ! -z "$message" ]; then
    full_message="${full_message} ${message}"
  fi

  `parse_gump_config`
  echo "Warning! About to run the following commands:"
  local item_count=1
  echo "  ${item_count}. git add ."; ((item_count++))
  echo "  ${item_count}. git commit --message \"$full_message\""; ((item_count++))
  echo "  ${item_count}. git tag $full_version"; ((item_count++))
  echo "  ${item_count}. git push"; ((item_count++))
  echo "  ${item_count}. git push --tags"; ((item_count++))
  echo "  ${item_count}. Run: git push"; ((item_count++))
  echo "  ${item_count}. Run: git push --tags"; ((item_count++))
  if [ "$gump_config_release_draft" == 'true' ]; then
    echo "  ${item_count}. Run: hub release create -d -m \"$full_message\" \"$full_version\""; ((item_count++))
  else
    echo "  ${item_count}. Run: hub release create -m \"$full_message\" \"$full_version\""; ((item_count++))
  fi
  echo "  ${item_count}. Run: curl --silent --fail -X POST \"$BEEKEEPER_URI/deployments/$slug/$tag\""; ((item_count++))
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
    &&  sleep 5 \
    &&  create_release "$full_message" "$full_version"
  else
    return 1
  fi
}

create_release() {
  local full_message="$1"
  local full_version="$2"
  `parse_gump_config`
  if [ "$gump_config_release_draft" == 'true' ]; then
    hub release create -d -m "$full_message" "$full_version"
  else
    hub release create -m "$full_message" "$full_version"
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
  local last_authors="$1"
  local users=""
  if [ "$last_authors" == 'true' ]; then
    if [ -f ~/.gump_last_authors ]; then
      users="$(cat ~/.gump_last_authors)"
      echo "Using last author(s): $users"
    fi
  fi
  if [ -z "$users" ]; then
    read -p 'Add author(s): ' users
  fi
  echo "$users" > ~/.gump_last_authors
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
  echo '  --major            major version bump. 1.0.0 -> 2.0.0'
  echo '  --minor            minor version bump. 1.0.0 -> 1.1.0'
  echo '  -p, --patch        patch version bump. 1.0.0 -> 1.0.1 (default)'
  echo '  -i, --init         set the version to 1.0.0'
  echo '  -l, --last-authors use the last author(s)'
  echo '  -h, --help         print this help text'
  echo '  -v, --version      print the version'
  echo ''
  echo 'config_file:'
  echo '  ** place config file (gump.yml) in the project directory **'
  echo '  possible values:'
  echo '    release:'
  echo '      draft: (bool) - Creates draft release in github. Defaults to false.'
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
  echo '  9. Post: $BEEKEEPER_URI/deployments'
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
  local bump='patch'
  local last_authors='false'
  local message
  while [ "$1" != "" ]; do
    local param="$1"
    local value="$2"
    case "$param" in
      -h | --help)
        usage
        exit 0
        ;;
      -v | --version)
        version
        exit 0
        ;;
      --major)
        bump="major"
        ;;
      --minor)
        bump="minor"
        ;;
      -p | --patch)
        bump="patch"
        ;;
      -i | --init)
        bump="init"
        ;;
      -l | --last-authors)
        last_authors='true'
        if [ "$value" == 'true' ]; then
          shift
        fi
        ;;
      *)
        if [ "${param::1}" == '-' ]; then
          echo "ERROR: unknown parameter \"$param\""
          usage
          exit 1
        fi
        if [ -z "$message" ]; then
          message="$param"
        fi
        ;;
    esac
    shift
  done

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
  assert_curl
  assert_required_env

  prompt_for_user "$last_authors"
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
  do_git_stuff "$new_version" "$message" && do_deploy "$new_version"
}

main "$@"
